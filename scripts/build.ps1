# Build VulkanSceneGraph + vsgXchange + vsgImGui as shared libraries (DLLs)
# on Windows with MSVC.
#
# Usage: scripts/build.ps1 -BuildType Release|Debug|RelWithDebInfo
#
# Must run inside an MSVC developer environment (vcvars / msvc-dev-cmd) so that
# cl.exe and ninja pick up the x64 toolchain. Requires the Vulkan SDK
# (VULKAN_SDK env var set, e.g. by humbletim/install-vulkan-sdk in CI).
#
# Helper dependencies (glslang for the VSG runtime shader compiler, assimp for
# the vsgXchange model loaders) are built as static libraries and absorbed
# into the DLLs. Everything installs into a single prefix per build type:
# _work/install/vsg-<BuildType>/.
#
# Environment overrides:
#   VSG_TAG        - vsg-dev/VulkanSceneGraph tag (default: v1.1.15)
#   VSGXCHANGE_TAG - vsg-dev/vsgXchange tag       (default: v1.1.13)
#   VSGIMGUI_TAG   - vsg-dev/vsgImGui tag         (default: v0.7.0)
#   ASSIMP_TAG     - assimp/assimp tag            (default: v6.0.4)
#   GLSLANG_TAG    - KhronosGroup/glslang tag     (default: 16.3.0)

param(
    [ValidateSet('Release', 'Debug', 'RelWithDebInfo')]
    [string]$BuildType = 'Release'
)

$ErrorActionPreference = 'Stop'

$VsgTag        = if ($env:VSG_TAG)        { $env:VSG_TAG }        else { 'v1.1.15' }
$VsgXchangeTag = if ($env:VSGXCHANGE_TAG) { $env:VSGXCHANGE_TAG } else { 'v1.1.13' }
$VsgImGuiTag   = if ($env:VSGIMGUI_TAG)   { $env:VSGIMGUI_TAG }   else { 'v0.7.0' }
$AssimpTag     = if ($env:ASSIMP_TAG)     { $env:ASSIMP_TAG }     else { 'v6.0.4' }
$GlslangTag    = if ($env:GLSLANG_TAG)    { $env:GLSLANG_TAG }    else { '16.3.0' }

$Root = Split-Path -Parent $PSScriptRoot
$Work = Join-Path $Root '_work'
$InstallDir = Join-Path $Work "install/vsg-$BuildType"
$DistDir = Join-Path $Work 'dist'

New-Item -ItemType Directory -Force -Path $Work, $DistDir | Out-Null

# Forward slashes: backslashed paths passed through -D can trip CMake escaping.
$InstallDirCM = $InstallDir -replace '\\', '/'

function Clone-Component {
    param([string]$Name, [string]$Url, [string]$Tag, [string[]]$ExtraArgs = @())
    $Dir = Join-Path $Work $Name
    if (Test-Path $Dir) { return }
    git clone --depth 1 --branch $Tag @ExtraArgs $Url $Dir
    if ($LASTEXITCODE -ne 0) { throw "git clone $Name failed" }
    # Local fixes on top of the upstream tag, if any (patches/<Name>/*.patch)
    $PatchDir = Join-Path $Root "patches/$Name"
    if (Test-Path $PatchDir) {
        foreach ($Patch in Get-ChildItem (Join-Path $PatchDir '*.patch')) {
            git -C $Dir apply --verbose $Patch.FullName
            if ($LASTEXITCODE -ne 0) { throw "Failed to apply patch $($Patch.Name)" }
        }
    }
}

function Build-Component {
    param([string]$Name, [string[]]$CMakeArgs)
    $BuildDir = Join-Path $Work "build-$Name-$BuildType"
    cmake -S (Join-Path $Work $Name) -B $BuildDir -G Ninja `
        -DCMAKE_BUILD_TYPE="$BuildType" `
        -DCMAKE_INSTALL_PREFIX="$InstallDirCM" `
        -DCMAKE_PREFIX_PATH="$InstallDirCM" `
        @CMakeArgs
    if ($LASTEXITCODE -ne 0) { throw "CMake configure ($Name) failed" }
    cmake --build $BuildDir
    if ($LASTEXITCODE -ne 0) { throw "Build ($Name) failed" }
    cmake --build $BuildDir --target install
    if ($LASTEXITCODE -ne 0) { throw "Install ($Name) failed" }
}

Clone-Component glslang    https://github.com/KhronosGroup/glslang.git     $GlslangTag
Clone-Component assimp     https://github.com/assimp/assimp.git            $AssimpTag
Clone-Component vsg        https://github.com/vsg-dev/VulkanSceneGraph.git $VsgTag
Clone-Component vsgxchange https://github.com/vsg-dev/vsgXchange.git       $VsgXchangeTag
# imgui + implot are git submodules compiled directly into the vsgImGui
# library (that is what makes the shared Windows build export the full ImGui
# API - see README).
Clone-Component vsgimgui   https://github.com/vsg-dev/vsgImGui.git         $VsgImGuiTag `
    @('--recurse-submodules', '--shallow-submodules')

# glslang - static, linked PRIVATE into vsg.dll (runtime GLSL->SPIR-V compiler
# behind VSG_SUPPORTS_ShaderCompiler). Same configuration as the vcpkg glslang
# port consumed by modeuler-ng: no spirv-opt, no standalone tools, no tests.
Build-Component glslang @(
    '-DBUILD_SHARED_LIBS=OFF',
    '-DBUILD_EXTERNAL=OFF',
    '-DGLSLANG_TESTS=OFF',
    '-DENABLE_OPT=OFF',
    '-DENABLE_GLSLANG_BINARIES=OFF'
)

# assimp - static, linked PRIVATE into vsgXchange.dll (model importers).
# Vendored zlib keeps the build hermetic on both platforms.
Build-Component assimp @(
    '-DBUILD_SHARED_LIBS=OFF',
    '-DASSIMP_BUILD_ZLIB=ON',
    '-DASSIMP_BUILD_TESTS=OFF',
    '-DASSIMP_BUILD_ASSIMP_TOOLS=OFF',
    '-DASSIMP_INSTALL_PDB=OFF',
    '-DASSIMP_WARNINGS_AS_ERRORS=OFF'
)

# VulkanSceneGraph - shared (DLL). Windowing (native Win32) and the glslang
# shader compiler are ON by default; both must survive into the artifact
# (checked below).
Build-Component vsg @(
    '-DBUILD_SHARED_LIBS=ON'
)

# VSG only *warns* and silently disables the shader compiler when glslang is
# not found - guard against shipping a degraded build. The installed
# vsgConfig.cmake contains find_package(glslang) iff the compiler is in.
$VsgConfig = Join-Path $InstallDir 'lib/cmake/vsg/vsgConfig.cmake'
if (-not (Select-String -Path $VsgConfig -Pattern 'find_package\(glslang' -Quiet)) {
    throw 'vsg was built WITHOUT the glslang shader compiler'
}

# vsgXchange - shared (DLL). assimp is the only optional dependency enabled
# (matches modeuler-ng's vcpkg feature set: vsgxchange[assimp]). The other
# optional deps are pre-seeded OFF so libraries present on the build host can
# never sneak in. stbi/dds/ktx-read/gltf/3DTiles readers are built-in.
Build-Component vsgxchange @(
    '-DBUILD_SHARED_LIBS=ON',
    '-DvsgXchange_freetype=OFF',
    '-DvsgXchange_curl=OFF',
    '-DvsgXchange_GDAL=OFF',
    '-DvsgXchange_openexr=OFF',
    '-DvsgXchange_ktx=OFF',
    '-DvsgXchange_draco=OFF',
    '-DvsgXchange_OSG=OFF'
)

# vsgXchange creates the vsgXchange_assimp option only when find_package
# succeeds, and falls back to a stub reader otherwise - so assert it is ON.
$XchangeCache = Join-Path $Work "build-vsgxchange-$BuildType/CMakeCache.txt"
if (-not (Select-String -Path $XchangeCache -Pattern '^vsgXchange_assimp:BOOL=ON' -Quiet)) {
    throw 'vsgXchange did not pick up assimp (stub reader would be shipped)'
}

# vsgImGui - shared (DLL), imgui + implot compiled in with
# IMGUI_API=__declspec(dllexport) via IMGUI_USER_CONFIG=<vsgImGui/Export.h>,
# so the DLL re-exports the FULL ImGui/ImPlot API to consumers (unlike the
# vcpkg port, which links a separate static imgui and re-exports nothing).
# SHOW_DEMO_WINDOW=OFF matches the vcpkg port.
Build-Component vsgimgui @(
    '-DBUILD_SHARED_LIBS=ON',
    '-DSHOW_DEMO_WINDOW=OFF'
)

$Archive = Join-Path $DistDir "vsg-$VsgTag-windows-x64-$BuildType.zip"
Compress-Archive -Path (Join-Path $Work "install/vsg-$BuildType") -DestinationPath $Archive -Force
Write-Host "Packaged: $Archive"
