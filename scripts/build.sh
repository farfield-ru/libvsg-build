#!/usr/bin/env bash
# Build VulkanSceneGraph + vsgXchange + vsgImGui as shared libraries on Linux.
#
# Usage: scripts/build.sh [Release|Debug|RelWithDebInfo]
#
# Helper dependencies (glslang for the VSG runtime shader compiler, assimp for
# the vsgXchange model loaders) are built as static PIC libraries and absorbed
# into the shared libraries. Everything installs into a single prefix per
# build type: _work/install/vsg-<BuildType>/.
#
# Environment overrides:
#   VSG_TAG        - vsg-dev/VulkanSceneGraph tag (default: v1.1.15)
#   VSGXCHANGE_TAG - vsg-dev/vsgXchange tag       (default: v1.1.13)
#   VSGIMGUI_TAG   - vsg-dev/vsgImGui tag         (default: v0.7.0)
#   ASSIMP_TAG     - assimp/assimp tag            (default: v6.0.4)
#   GLSLANG_TAG    - KhronosGroup/glslang tag     (default: 16.3.0)

set -euo pipefail

BUILD_TYPE="${1:-Release}"
case "$BUILD_TYPE" in
  Release|Debug|RelWithDebInfo) ;;
  *) echo "Unsupported build type '$BUILD_TYPE'. Supported: Release, Debug, RelWithDebInfo" >&2; exit 1 ;;
esac

VSG_TAG="${VSG_TAG:-v1.1.15}"
VSGXCHANGE_TAG="${VSGXCHANGE_TAG:-v1.1.13}"
VSGIMGUI_TAG="${VSGIMGUI_TAG:-v0.7.0}"
ASSIMP_TAG="${ASSIMP_TAG:-v6.0.4}"
GLSLANG_TAG="${GLSLANG_TAG:-16.3.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/_work"
INSTALL_DIR="$WORK/install/vsg-$BUILD_TYPE"
DIST_DIR="$WORK/dist"

mkdir -p "$WORK" "$DIST_DIR"

# Release-only codegen tuning (same rationale as farfield-ru/libocct-build):
#   -march=x86-64-v2 - safe ISA baseline for distributed binaries (~2009+ CPUs).
# No LTO: unlike OCCT there is no upstream-supported LTO profile for these
# libraries, and the win would be small relative to the added toolchain risk.
OPT_FLAGS=""
if [ "$BUILD_TYPE" = "Release" ]; then
  OPT_FLAGS="-march=x86-64-v2"
fi

clone() { # clone <dir-name> <url> <tag> [extra git-clone args...]
  local name="$1" url="$2" tag="$3"
  shift 3
  local dir="$WORK/$name"
  [ -d "$dir" ] && return 0
  git clone --depth 1 --branch "$tag" "$@" "$url" "$dir"
  # Local fixes on top of the upstream tag, if any (patches/<dir-name>/*.patch)
  local patch
  for patch in "$ROOT/patches/$name/"*.patch; do
    [ -e "$patch" ] || continue
    git -C "$dir" apply --verbose "$patch"
  done
}

build() { # build <dir-name> [cmake args...]
  local name="$1"
  shift
  local bdir="$WORK/build-$name-$BUILD_TYPE"
  cmake -S "$WORK/$name" -B "$bdir" -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
    -DCMAKE_C_FLAGS="$OPT_FLAGS" \
    -DCMAKE_CXX_FLAGS="$OPT_FLAGS" \
    "$@"
  cmake --build "$bdir"
  cmake --build "$bdir" --target install
}

clone glslang  https://github.com/KhronosGroup/glslang.git      "$GLSLANG_TAG"
clone assimp   https://github.com/assimp/assimp.git             "$ASSIMP_TAG"
clone vsg      https://github.com/vsg-dev/VulkanSceneGraph.git  "$VSG_TAG"
clone vsgxchange https://github.com/vsg-dev/vsgXchange.git      "$VSGXCHANGE_TAG"
# imgui + implot are git submodules compiled directly into the vsgImGui
# library (that is what makes the shared Windows build export the full ImGui
# API - see README).
clone vsgimgui https://github.com/vsg-dev/vsgImGui.git          "$VSGIMGUI_TAG" \
  --recurse-submodules --shallow-submodules

# glslang - static, linked PRIVATE into libvsg.so (runtime GLSL->SPIR-V
# compiler behind VSG_SUPPORTS_ShaderCompiler). Same configuration as the
# vcpkg glslang port consumed by modeuler-ng: no spirv-opt (ENABLE_OPT=OFF),
# no standalone tools, no tests.
build glslang \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_EXTERNAL=OFF \
  -DGLSLANG_TESTS=OFF \
  -DENABLE_OPT=OFF \
  -DENABLE_GLSLANG_BINARIES=OFF

# assimp - static, linked PRIVATE into libvsgXchange.so (model importers).
# Vendored zlib keeps the build hermetic on both platforms.
build assimp \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DASSIMP_BUILD_ZLIB=ON \
  -DASSIMP_BUILD_TESTS=OFF \
  -DASSIMP_BUILD_ASSIMP_TOOLS=OFF \
  -DASSIMP_INSTALL_PDB=OFF \
  -DASSIMP_WARNINGS_AS_ERRORS=OFF

# VulkanSceneGraph - shared. Windowing (xcb) and the glslang shader compiler
# are ON by default; both must survive into the artifact (checked below).
#
# VSG_SUPPORTS_ShaderOptimizer is pre-seeded OFF for the same reason the
# vsgXchange options below are: upstream defaults it ON and then quietly keeps
# it if find_package(SPIRV-Tools-opt) happens to succeed, so whatever is
# installed on the build host decides what ends up in the artifact. It also
# matches -DENABLE_OPT=OFF on glslang above and the vcpkg configuration this
# build replaces, neither of which has the optimizer.
build vsg \
  -DBUILD_SHARED_LIBS=ON \
  -DVSG_SUPPORTS_ShaderOptimizer=OFF

# VSG only *warns* and silently disables the shader compiler when glslang is
# not found - guard against shipping a degraded build. The installed
# vsgConfig.cmake contains find_package(glslang) iff the compiler is in.
if ! grep -q "find_package(glslang" "$INSTALL_DIR/lib/cmake/vsg/vsgConfig.cmake"; then
  echo "ERROR: vsg was built WITHOUT the glslang shader compiler" >&2
  exit 1
fi

# The mirror of that check, for the optimizer. vsgConfig.cmake is generated as
#   if (@VSG_SUPPORTS_ShaderOptimizer@)
#       find_dependency(SPIRV-Tools-opt)
# so a host-detected optimizer makes EVERY consumer need a SPIRV-Tools-opt
# package this artifact does not ship, and find_package(vsg) fails outright.
# Test the generated gate line itself rather than the whole file, so an
# unrelated `if (ON)` in a future VSG config template cannot mask this.
if grep -B1 "find_dependency(SPIRV-Tools-opt)" \
     "$INSTALL_DIR/lib/cmake/vsg/vsgConfig.cmake" | grep -q "if (ON)"; then
  echo "ERROR: vsg picked up SPIRV-Tools from the build host - vsgConfig.cmake" >&2
  echo "       now requires a SPIRV-Tools-opt package this artifact does not ship" >&2
  exit 1
fi

# vsgXchange - shared. assimp is the only optional dependency enabled
# (matches modeuler-ng's vcpkg feature set: vsgxchange[assimp]). The other
# optional deps are pre-seeded OFF so libraries present on the build host can
# never sneak in. stbi/dds/ktx-read/gltf/3DTiles readers are built-in.
build vsgxchange \
  -DBUILD_SHARED_LIBS=ON \
  -DvsgXchange_freetype=OFF \
  -DvsgXchange_curl=OFF \
  -DvsgXchange_GDAL=OFF \
  -DvsgXchange_openexr=OFF \
  -DvsgXchange_ktx=OFF \
  -DvsgXchange_draco=OFF \
  -DvsgXchange_OSG=OFF

# vsgXchange creates the vsgXchange_assimp option only when find_package
# succeeds, and falls back to a stub reader otherwise - so assert it is ON.
if ! grep -q "^vsgXchange_assimp:BOOL=ON" "$WORK/build-vsgxchange-$BUILD_TYPE/CMakeCache.txt"; then
  echo "ERROR: vsgXchange did not pick up assimp (stub reader would be shipped)" >&2
  exit 1
fi

# vsgImGui - shared, imgui + implot compiled in and re-exported.
# SHOW_DEMO_WINDOW=OFF matches the vcpkg port (ImGui::ShowDemoWindow becomes
# a no-op stub).
build vsgimgui \
  -DBUILD_SHARED_LIBS=ON \
  -DSHOW_DEMO_WINDOW=OFF

# Consume the prefix the way a downstream project does - find_package,
# compile, link, run - before packaging it. Building the libraries proves they
# compile; only this proves the INSTALL is usable. CMAKE_PREFIX_PATH is the
# install dir alone, so anything the artifact fails to provide surfaces here.
SMOKE_BUILD="$WORK/build-smoke-$BUILD_TYPE"
rm -rf "$SMOKE_BUILD"
cmake -S "$ROOT/scripts/smoke" -B "$SMOKE_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_PREFIX_PATH="$INSTALL_DIR"
cmake --build "$SMOKE_BUILD"
# Running (unlike linking) also needs libvulkan.so.1 on the loader path. It is
# NOT added here: GitHub's ubuntu images ship it, and locally it comes from
# libvulkan-dev / an inherited LD_LIBRARY_PATH. If this fails to load, that is
# the missing piece.
LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}" "$SMOKE_BUILD/vsg_smoke"

ARCHIVE="$DIST_DIR/vsg-$VSG_TAG-linux-x64-$BUILD_TYPE.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK/install" "vsg-$BUILD_TYPE"
echo "Packaged: $ARCHIVE"
