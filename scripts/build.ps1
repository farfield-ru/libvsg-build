# Build VulkanSceneGraph + vsgXchange + vsgImGui as shared libraries (DLLs)
# on Windows with MSVC.
#
# Usage: scripts/build.ps1 -BuildType Release|Debug|RelWithDebInfo
#
# Must run inside an MSVC developer environment (vcvars / msvc-dev-cmd) so that
# cl.exe and ninja pick up the x64 toolchain. NO Vulkan SDK is required: the
# Vulkan headers and loader are built from pinned Khronos tags and installed
# into the prefix, so the artifact satisfies find_package(Vulkan) and ships its
# own vulkan-1.dll.
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
#   VULKAN_TAG     - Khronos Vulkan-Headers/Loader tag (default: vulkan-sdk-1.4.341.0)

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
# Vulkan-Headers and Vulkan-Loader are built and INSTALLED INTO THE PREFIX so
# the artifact satisfies find_package(Vulkan) by itself and carries its own
# vulkan-1.dll - consumers (and the smoke test) then need no Vulkan SDK at all.
$VulkanTag     = if ($env:VULKAN_TAG)     { $env:VULKAN_TAG }     else { 'vulkan-sdk-1.4.341.0' }

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

Clone-Component vulkan-headers https://github.com/KhronosGroup/Vulkan-Headers.git $VulkanTag
Clone-Component vulkan-loader  https://github.com/KhronosGroup/Vulkan-Loader.git  $VulkanTag
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
# Vulkan-Headers - header only. Must precede the loader and vsg, both of which
# find_package(Vulkan) against the prefix.
Build-Component vulkan-headers @()

# Vulkan-Loader - vulkan-1.dll into the prefix. WSI on Windows is Win32, which
# the loader enables by default, so unlike the Linux script there are no
# BUILD_WSI_* overrides to make here.
Build-Component vulkan-loader @(
    '-DBUILD_TESTS=OFF'
)

# A loader that did not produce its DLL leaves every consumer (and the smoke
# test below) dying at load time with a silent 0xC0000135.
$LoaderDll = Join-Path $InstallDir 'bin/vulkan-1.dll'
if (-not (Test-Path $LoaderDll)) {
    throw "the Vulkan loader build produced no vulkan-1.dll at $LoaderDll"
}

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
# VSG_SUPPORTS_ShaderOptimizer is pre-seeded OFF for the same reason the
# vsgXchange options below are: upstream defaults it ON and then quietly keeps
# it if find_package(SPIRV-Tools-opt) happens to succeed, so whatever is
# installed on the build host decides what ends up in the artifact. It also
# matches -DENABLE_OPT=OFF on glslang above and the vcpkg configuration this
# build replaces, neither of which has the optimizer.
Build-Component vsg @(
    '-DBUILD_SHARED_LIBS=ON',
    '-DVSG_SUPPORTS_ShaderOptimizer=OFF'
)

# VSG only *warns* and silently disables the shader compiler when glslang is
# not found - guard against shipping a degraded build. The installed
# vsgConfig.cmake contains find_package(glslang) iff the compiler is in.
$VsgConfig = Join-Path $InstallDir 'lib/cmake/vsg/vsgConfig.cmake'
if (-not (Select-String -Path $VsgConfig -Pattern 'find_package\(glslang' -Quiet)) {
    throw 'vsg was built WITHOUT the glslang shader compiler'
}

# The mirror of that check, for the optimizer. vsgConfig.cmake is generated as
#   if (@VSG_SUPPORTS_ShaderOptimizer@)
#       find_dependency(SPIRV-Tools-opt)
# so a host-detected optimizer makes EVERY consumer need a SPIRV-Tools-opt
# package this artifact does not ship, and find_package(vsg) fails outright.
# Test the generated gate line itself rather than the whole file, so an
# unrelated 'if (ON)' in a future VSG config template cannot mask this.
$VsgConfigLines = Get-Content $VsgConfig
for ($i = 1; $i -lt $VsgConfigLines.Count; $i++) {
    if ($VsgConfigLines[$i] -match 'find_dependency\(SPIRV-Tools-opt\)' -and
        $VsgConfigLines[$i - 1] -match 'if \(ON\)') {
        throw ('vsg picked up SPIRV-Tools from the build host - vsgConfig.cmake ' +
               'now requires a SPIRV-Tools-opt package this artifact does not ship')
    }
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

# Consume the prefix the way a downstream project does - find_package,
# compile, link, run - before packaging it. Building the libraries proves they
# compile; only this proves the INSTALL is usable. CMAKE_PREFIX_PATH is the
# install dir alone, so anything the artifact fails to provide surfaces here.
# On Windows this is also the guard for the ImGui re-export: a vsgImGui DLL
# that does not re-export the ImGui API fails to link main.cpp with LNK2019.
$SmokeBuild = Join-Path $Work "build-smoke-$BuildType"
if (Test-Path $SmokeBuild) { Remove-Item -Recurse -Force $SmokeBuild }
cmake -S (Join-Path $Root 'scripts/smoke') -B $SmokeBuild -G Ninja `
    "-DCMAKE_BUILD_TYPE=$BuildType" `
    "-DCMAKE_PREFIX_PATH=$InstallDirCM"
if ($LASTEXITCODE -ne 0) { throw 'smoke test failed to configure against the install prefix' }
cmake --build $SmokeBuild
if ($LASTEXITCODE -ne 0) { throw 'smoke test failed to build against the install prefix' }
# Running (unlike linking) also needs the Vulkan runtime loader vulkan-1.dll
# resolvable. It now ships in the prefix's own bin/ alongside the VSG DLLs, so
# prepending that directory covers it and no SDK or System32 copy is involved.
# A missing-DLL death is silent (exit 0xC0000135), hence the exit code in the
# message.
$env:PATH = (Join-Path $InstallDir 'bin') + [IO.Path]::PathSeparator + $env:PATH
& (Join-Path $SmokeBuild 'vsg_smoke.exe')
if ($LASTEXITCODE -ne 0) { throw "smoke test binary failed to run (exit $LASTEXITCODE)" }

$Archive = Join-Path $DistDir "vsg-$VsgTag-windows-x64-$BuildType.zip"
Compress-Archive -Path (Join-Path $Work "install/vsg-$BuildType") -DestinationPath $Archive -Force
Write-Host "Packaged: $Archive"
