# Build VulkanSceneGraph + vsgXchange + vsgImGui as STATIC libraries on
# Windows with MSVC, consumed through a single dependency-free CMake config:
#
#   find_package(vsgall CONFIG REQUIRED)   ->   vsgall::vsgall
#
# Static + one hand-written config is the answer to issue #4: the shared-lib
# artifact made every consumer stage DLLs across build/publish/test and
# re-find Vulkan/glslang at configure time.
#
# Usage: scripts/build.ps1 -BuildType Release|Debug|RelWithDebInfo
#
# Must run inside an MSVC developer environment (vcvars / msvc-dev-cmd) so that
# cl.exe and ninja pick up the x64 toolchain. NO Vulkan SDK is required: the
# Vulkan headers and loader are built from pinned Khronos tags. The prefix
# ships the headers and the LINK artifact (vulkan-1.lib) only - the RUNTIME
# loader (vulkan-1.dll) is a driver-integration component owned by the host
# system and is deliberately not shipped.
#
# All static archives are built against the DYNAMIC CRT (/MD, /MDd for Debug)
# to match modeuler-ng's stock triplets - stated explicitly below rather than
# relying on CMake's default.
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
# Vulkan-Headers and Vulkan-Loader tags track the SDK version this repo used
# to install on the runners before it started building Vulkan itself.
$VulkanTag     = if ($env:VULKAN_TAG)     { $env:VULKAN_TAG }     else { 'vulkan-sdk-1.4.341.0' }

$Root = Split-Path -Parent $PSScriptRoot
$Work = Join-Path $Root '_work'
$InstallDir = Join-Path $Work "install/vsg-$BuildType"
$DistDir = Join-Path $Work 'dist'

New-Item -ItemType Directory -Force -Path $Work, $DistDir | Out-Null

# Forward slashes: backslashed paths passed through -D can trip CMake escaping.
$InstallDirCM = $InstallDir -replace '\\', '/'

# Static archives must use the same CRT family as the consumer, and
# modeuler-ng builds with the stock dynamic CRT (/MD; /MDd for Debug).
# CMake's default agrees, but the CRT of a static library is an ABI contract
# with every consumer - state it, don't inherit it.
$CrtFlag = '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded$<$<CONFIG:Debug>:Debug>DLL'

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
# library, so the archive carries the full ImGui/ImPlot object set.
Clone-Component vsgimgui   https://github.com/vsg-dev/vsgImGui.git         $VsgImGuiTag `
    @('--recurse-submodules', '--shallow-submodules')

# Vulkan-Headers - header only. Must precede the loader and vsg, both of which
# find_package(Vulkan) against the prefix.
Build-Component vulkan-headers @()

# Vulkan-Loader - built as usual, but only its LINK artifact (vulkan-1.lib) is
# kept below. WSI on Windows is Win32, which the loader enables by default, so
# unlike the Linux script there are no BUILD_WSI_* overrides to make here.
Build-Component vulkan-loader @(
    '-DBUILD_TESTS=OFF'
)

# Keep the LINK artifact only. Consumers link against the prefix's
# vulkan-1.lib; at runtime vulkan-1.dll comes from the host system (GPU
# drivers install it), exactly as with the Vulkan SDK. The smoke test below
# takes its runtime loader from the loader's build tree instead.
$LoaderImportLib = Join-Path $InstallDir 'lib/vulkan-1.lib'
if (-not (Test-Path $LoaderImportLib)) {
    throw "the Vulkan loader build produced no import library at $LoaderImportLib"
}
$LoaderDll = Join-Path $InstallDir 'bin/vulkan-1.dll'
if (Test-Path $LoaderDll) { Remove-Item $LoaderDll }

# glslang - static (runtime GLSL->SPIR-V compiler behind
# VSG_SUPPORTS_ShaderCompiler). Same configuration as the vcpkg glslang port
# modeuler-ng used to consume: no spirv-opt, no standalone tools, no tests.
Build-Component glslang @(
    '-DBUILD_SHARED_LIBS=OFF',
    $CrtFlag,
    '-DBUILD_EXTERNAL=OFF',
    '-DGLSLANG_TESTS=OFF',
    '-DENABLE_OPT=OFF',
    '-DENABLE_GLSLANG_BINARIES=OFF'
)

# assimp - static (model importers). Vendored zlib keeps the build hermetic
# on both platforms.
Build-Component assimp @(
    '-DBUILD_SHARED_LIBS=OFF',
    $CrtFlag,
    '-DASSIMP_BUILD_ZLIB=ON',
    '-DASSIMP_BUILD_TESTS=OFF',
    '-DASSIMP_BUILD_ASSIMP_TOOLS=OFF',
    '-DASSIMP_INSTALL_PDB=OFF',
    '-DASSIMP_WARNINGS_AS_ERRORS=OFF'
)

# VulkanSceneGraph - STATIC. Windowing (native Win32) and the glslang shader
# compiler are ON by default; both must survive into the artifact (checked
# below).
# VSG_SUPPORTS_ShaderOptimizer is pre-seeded OFF for the same reason the
# vsgXchange options below are: upstream defaults it ON and then quietly keeps
# it if find_package(SPIRV-Tools-opt) happens to succeed, so whatever is
# installed on the build host decides what ends up in the artifact. It also
# matches -DENABLE_OPT=OFF on glslang above and the vcpkg configuration this
# build replaces, neither of which has the optimizer.
Build-Component vsg @(
    '-DBUILD_SHARED_LIBS=OFF',
    $CrtFlag,
    '-DVSG_SUPPORTS_ShaderOptimizer=OFF'
)

# VSG only *warns* and silently disables the shader compiler when glslang is
# not found - guard against shipping a degraded build. The installed
# vsgConfig.cmake contains find_package(glslang) iff the compiler is in.
# (The upstream configs are removed from the artifact further down; at this
# point in the build they are still the most direct record of what vsg did.)
$VsgConfig = Join-Path $InstallDir 'lib/cmake/vsg/vsgConfig.cmake'
if (-not (Select-String -Path $VsgConfig -Pattern 'find_package\(glslang' -Quiet)) {
    throw 'vsg was built WITHOUT the glslang shader compiler'
}

# The mirror of that check, for the optimizer. vsgConfig.cmake is generated as
#   if (@VSG_SUPPORTS_ShaderOptimizer@)
#       find_dependency(SPIRV-Tools-opt)
# so a host-detected optimizer means vsg was built against SPIRV-Tools this
# artifact does not ship. Test the generated gate line itself rather than the
# whole file, so an unrelated 'if (ON)' in a future VSG config template cannot
# mask this.
$VsgConfigLines = Get-Content $VsgConfig
for ($i = 1; $i -lt $VsgConfigLines.Count; $i++) {
    if ($VsgConfigLines[$i] -match 'find_dependency\(SPIRV-Tools-opt\)' -and
        $VsgConfigLines[$i - 1] -match 'if \(ON\)') {
        throw ('vsg picked up SPIRV-Tools from the build host - the artifact ' +
               'would depend on a SPIRV-Tools-opt package it does not ship')
    }
}

# vsgXchange - static. assimp is the only optional dependency enabled
# (matches modeuler-ng's vcpkg feature set: vsgxchange[assimp]). The other
# optional deps are pre-seeded OFF so libraries present on the build host can
# never sneak in. stbi/dds/ktx-read/gltf/3DTiles readers are built-in.
Build-Component vsgxchange @(
    '-DBUILD_SHARED_LIBS=OFF',
    $CrtFlag,
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

# vsgImGui - static, imgui + implot compiled in from its pinned submodules,
# so the archive carries the complete ImGui/ImPlot object set and consumers
# can call the entire API. SHOW_DEMO_WINDOW=OFF matches the vcpkg port.
Build-Component vsgimgui @(
    '-DBUILD_SHARED_LIBS=OFF',
    $CrtFlag,
    '-DSHOW_DEMO_WINDOW=OFF'
)

# ---------------------------------------------------------------------------
# Package config: one hand-written vsgallConfig.cmake, ZERO package lookups.
#
# Upstream's per-package configs re-find Vulkan and glslang because upstream
# links them dynamically; with everything absorbed into static archives those
# lookups are pure integration cost for consumers (issue #4: Vulkan_ROOT /
# glslang_DIR plumbing and a vcpkg vulkan port). The prefix ships exactly ONE
# cmake file, stating the link line by path, and the upstream configs are
# removed so nothing can quietly depend on them.

function Find-OneLib {
    # Candidates cover the per-config name postfixes of every upstream
    # project ("d"/"rd" from vsgMacros, "d" from glslang and assimp on
    # Windows) so this script does not encode which project applies which
    # postfix - but a pattern set matching zero or several files fails the
    # build.
    param([string]$Label, [string[]]$Patterns)
    $LibDir = Join-Path $InstallDir 'lib'
    $Found = @()
    foreach ($P in $Patterns) {
        $Found += @(Get-ChildItem -Path $LibDir -Filter $P -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name)
    }
    $Found = @($Found | Sort-Object -Unique)
    if ($Found.Count -ne 1) {
        throw ("expected exactly one archive for $Label in $LibDir " +
               "(patterns: $($Patterns -join ', ')), found: [$($Found -join ', ')]")
    }
    $Found[0]
}

$Libs = @(
    (Find-OneLib 'vsgXchange' @('vsgXchange.lib', 'vsgXchanged.lib', 'vsgXchangerd.lib')),
    (Find-OneLib 'vsgImGui'   @('vsgImGui.lib', 'vsgImGuid.lib', 'vsgImGuird.lib')),
    (Find-OneLib 'vsg'        @('vsg.lib', 'vsgd.lib', 'vsgrd.lib')),
    (Find-OneLib 'glslang-default-resource-limits' `
        @('glslang-default-resource-limits.lib', 'glslang-default-resource-limitsd.lib')),
    (Find-OneLib 'glslang'    @('glslang.lib', 'glslangd.lib')),
    (Find-OneLib 'SPIRV'      @('SPIRV.lib', 'SPIRVd.lib')),
    (Find-OneLib 'MachineIndependent' @('MachineIndependent.lib', 'MachineIndependentd.lib')),
    (Find-OneLib 'GenericCodeGen'     @('GenericCodeGen.lib', 'GenericCodeGend.lib')),
    (Find-OneLib 'OSDependent'        @('OSDependent.lib', 'OSDependentd.lib')),
    (Find-OneLib 'assimp'     @('assimp-*.lib')),
    (Find-OneLib 'zlib'       @('zlibstatic.lib', 'zlibstaticd.lib')),
    'vulkan-1.lib'
)

# Drop everything package-shaped the upstream installs left behind: cmake
# package dirs (vsg, vsgXchange, vsgImGui, glslang, assimp, VulkanHeaders,
# VulkanLoader), pkg-config files, and the Vulkan XML registry (consumers
# compile against include/vulkan; nothing reads the registry).
foreach ($Junk in @('lib/cmake', 'lib/pkgconfig', 'share/vulkan', 'share/cmake')) {
    $JunkPath = Join-Path $InstallDir $Junk
    if (Test-Path $JunkPath) { Remove-Item -Recurse -Force $JunkPath }
}
$SharePath = Join-Path $InstallDir 'share'
if ((Test-Path $SharePath) -and -not (Get-ChildItem $SharePath)) {
    Remove-Item $SharePath
}

$VsgallDir = Join-Path $InstallDir 'lib/cmake/vsgall'
New-Item -ItemType Directory -Force -Path $VsgallDir | Out-Null

# Single-quoted here-string: ${...} and $<...> must reach CMake literally.
$ConfigTemplate = @'
# vsgallConfig.cmake - generated by farfield-ru/libvsg-build for
# VulkanSceneGraph __VSG_TAG__ (__BUILD_TYPE__, Windows x64, MSVC, dynamic
# CRT). The single supported entry point of this prefix:
#
#   find_package(vsgall CONFIG REQUIRED)
#   target_link_libraries(app PRIVATE vsgall::vsgall)
#
# Deliberately contains NO find_dependency/find_package/pkg_check_modules.
# Every dependency is a static archive inside this prefix, stated below by
# path. The Vulkan entry is the LINK artifact (vulkan-1.lib); the runtime
# loader (vulkan-1.dll) comes from the host system at run time.

if(TARGET vsgall::vsgall)
  return()
endif()

get_filename_component(_vsgall_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

add_library(vsgall::vsgall INTERFACE IMPORTED)
set_target_properties(vsgall::vsgall PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${_vsgall_prefix}/include"
  INTERFACE_COMPILE_FEATURES "cxx_std_17")

# Static link order: each archive precedes the archives it pulls symbols from.
set_property(TARGET vsgall::vsgall PROPERTY INTERFACE_LINK_LIBRARIES
__LIB_LINES__)

unset(_vsgall_prefix)

set(vsgall_VERSION "__VSG_VERSION__")
'@

$LibLines = ($Libs | ForEach-Object { '  "${_vsgall_prefix}/lib/' + $_ + '"' }) -join "`n"
$Config = $ConfigTemplate.
    Replace('__VSG_TAG__', $VsgTag).
    Replace('__BUILD_TYPE__', $BuildType).
    Replace('__LIB_LINES__', $LibLines).
    Replace('__VSG_VERSION__', $VsgTag.TrimStart('v'))
Set-Content -Path (Join-Path $VsgallDir 'vsgallConfig.cmake') -Value $Config -NoNewline

# Lock the config's defining property in: no package lookups, ever. Comments
# are stripped first - the config's own header legitimately NAMES the banned
# commands while promising their absence.
$ConfigCode = (Get-Content (Join-Path $VsgallDir 'vsgallConfig.cmake')) -replace '#.*' -join "`n"
if ($ConfigCode -match 'find_dependency|find_package|pkg_check_modules') {
    throw 'vsgallConfig.cmake grew a package lookup'
}

# And the artifact-wide version of the same promise: vsgallConfig.cmake is
# the ONLY cmake file the prefix ships.
$ShippedCMake = @(Get-ChildItem -Path $InstallDir -Recurse -Filter '*.cmake')
if ($ShippedCMake.Count -ne 1 -or $ShippedCMake[0].Name -ne 'vsgallConfig.cmake') {
    throw "unexpected cmake files in the prefix: $($ShippedCMake.FullName -join ', ')"
}

# ---------------------------------------------------------------------------
# Consume the prefix the way a downstream project does - find_package(vsgall),
# compile, link, run - before packaging it. Building the libraries proves they
# compile; only this proves the INSTALL is usable.
#
# Scrubbed environment: a full env -i is impossible here (cl.exe needs the
# vcvars INCLUDE/LIB/PATH), so scrub the variables through which a package
# source could leak into the configure - anything the prefix fails to provide
# must surface HERE instead of in a consumer.
foreach ($Var in @('VULKAN_SDK', 'CMAKE_PREFIX_PATH', 'CMAKE_MODULE_PATH',
                   'VCPKG_ROOT', 'VCPKG_INSTALLATION_ROOT')) {
    if (Test-Path "Env:$Var") { Remove-Item "Env:$Var" }
}

$SmokeBuild = Join-Path $Work "build-smoke-$BuildType"
if (Test-Path $SmokeBuild) { Remove-Item -Recurse -Force $SmokeBuild }
cmake -S (Join-Path $Root 'scripts/smoke') -B $SmokeBuild -G Ninja `
    "-DCMAKE_BUILD_TYPE=$BuildType" `
    "-DCMAKE_PREFIX_PATH=$InstallDirCM"
if ($LASTEXITCODE -ne 0) { throw 'smoke test failed to configure against the install prefix' }
cmake --build $SmokeBuild
if ($LASTEXITCODE -ne 0) { throw 'smoke test failed to build against the install prefix' }

# Running also needs a RUNTIME Vulkan loader, which the prefix deliberately
# does not ship (on end-user machines the GPU driver provides vulkan-1.dll;
# fresh CI VMs have none). Take the one just built, from the loader's BUILD
# tree - runtime-loader provisioning belongs to the build environment, not to
# the artifact. A missing-DLL death is silent (exit 0xC0000135), hence the
# exit code in the message.
$LoaderRuntimeDir = Join-Path $Work "build-vulkan-loader-$BuildType/loader"
if (-not (Test-Path (Join-Path $LoaderRuntimeDir 'vulkan-1.dll'))) {
    throw "no runtime loader at $LoaderRuntimeDir to run the smoke test with"
}
$env:PATH = $LoaderRuntimeDir + [IO.Path]::PathSeparator + $env:PATH
& (Join-Path $SmokeBuild 'vsg_smoke.exe')
if ($LASTEXITCODE -ne 0) { throw "smoke test binary failed to run (exit $LASTEXITCODE)" }

$Archive = Join-Path $DistDir "vsg-$VsgTag-windows-x64-$BuildType.zip"
Compress-Archive -Path (Join-Path $Work "install/vsg-$BuildType") -DestinationPath $Archive -Force
Write-Host "Packaged: $Archive"
