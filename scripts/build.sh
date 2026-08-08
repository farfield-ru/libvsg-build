#!/usr/bin/env bash
# Build VulkanSceneGraph + vsgXchange + vsgImGui as STATIC (PIC) libraries on
# Linux, consumed through a single dependency-free CMake config:
#
#   find_package(vsgall CONFIG REQUIRED)   ->   vsgall::vsgall
#
# Static + one hand-written config is the answer to issue #4: the shared-lib
# artifact made every consumer stage libraries, manage rpaths and re-find
# Vulkan/glslang/xcb at configure time - integration cost that scales with how
# many places a dependency touches the consumer's build.
#
# No Vulkan SDK is required: the Vulkan headers and loader are built from
# pinned Khronos tags. The prefix ships the headers and the LINK artifact
# (libvulkan.so) only - the RUNTIME loader is a driver-integration component
# owned by the host system, like libGL, and is deliberately not shipped.
#
# glslang (VSG runtime shader compiler) and assimp (vsgXchange model loaders)
# are static PIC as before; now nothing absorbs them at build time - the
# generated vsgallConfig.cmake states the whole static link line instead.
# Everything installs into a single prefix per build type:
# _work/install/vsg-<BuildType>/.
#
# Environment overrides:
#   VSG_TAG        - vsg-dev/VulkanSceneGraph tag (default: v1.1.15)
#   VSGXCHANGE_TAG - vsg-dev/vsgXchange tag       (default: v1.1.13)
#   VSGIMGUI_TAG   - vsg-dev/vsgImGui tag         (default: v0.7.0)
#   ASSIMP_TAG     - assimp/assimp tag            (default: v6.0.4)
#   GLSLANG_TAG    - KhronosGroup/glslang tag     (default: 16.3.0)
#   VULKAN_TAG     - Khronos Vulkan-Headers/Loader tag (default: vulkan-sdk-1.4.341.0)

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
# Vulkan-Headers and Vulkan-Loader tags track the SDK version this repo used
# to install on the runners before it started building Vulkan itself.
VULKAN_TAG="${VULKAN_TAG:-vulkan-sdk-1.4.341.0}"

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

# Every static archive is compiled with hidden symbol visibility: its objects
# end up inside a consumer's SHARED object, and default visibility would turn
# every absorbed vsg/glslang/assimp/zlib symbol into an export of that library
# (modeuler-ng's libmodeuler_ng.so measurably exported 521 foreign symbols -
# adler32, aiGetMaterialColor, ... - a live collision hazard for anything else
# in the process). The smoke test below FAILS the build if these leak back in.
# The Vulkan loader is exempt: it is a real shared library that manages its
# own exports.
VIS_C_FLAGS="-fvisibility=hidden"
VIS_CXX_FLAGS="-fvisibility=hidden -fvisibility-inlines-hidden"

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
  # Call sites may append their own -DCMAKE_C_FLAGS/-DCMAKE_CXX_FLAGS; the
  # later duplicate on a cmake command line wins over the defaults set here.
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

clone vulkan-headers https://github.com/KhronosGroup/Vulkan-Headers.git "$VULKAN_TAG"
clone vulkan-loader  https://github.com/KhronosGroup/Vulkan-Loader.git  "$VULKAN_TAG"
clone glslang  https://github.com/KhronosGroup/glslang.git      "$GLSLANG_TAG"
clone assimp   https://github.com/assimp/assimp.git             "$ASSIMP_TAG"
clone vsg      https://github.com/vsg-dev/VulkanSceneGraph.git  "$VSG_TAG"
clone vsgxchange https://github.com/vsg-dev/vsgXchange.git      "$VSGXCHANGE_TAG"
# imgui + implot are git submodules compiled directly into the vsgImGui
# library, so the archive carries the full ImGui/ImPlot object set.
clone vsgimgui https://github.com/vsg-dev/vsgImGui.git          "$VSGIMGUI_TAG" \
  --recurse-submodules --shallow-submodules

# Vulkan-Headers - header only. Must be installed before the loader and before
# vsg, both of which find_package(Vulkan) against the prefix.
build vulkan-headers

# Vulkan-Loader - built shared, but only its LINK artifact is kept below. WSI:
# XCB only, which EXACTLY matches the loader this build previously took from
# vcpkg/the SDK - verified by comparing exported surface entry points
# (vkCreateXcbSurfaceKHR + vkCreateDisplayPlaneSurfaceKHR, no Xlib, no
# Wayland). Leaving Xlib on would also drag an xrandr dev package in for a
# surface type VSG never creates: it takes an xcb_window_t.
build vulkan-loader \
  -DBUILD_TESTS=OFF \
  -DBUILD_WSI_XCB_SUPPORT=ON \
  -DBUILD_WSI_XLIB_SUPPORT=OFF \
  -DBUILD_WSI_WAYLAND_SUPPORT=OFF

# Keep the LINK artifact only. Consumers link against the prefix's
# libvulkan.so; at runtime the dynamic linker resolves its SONAME
# (libvulkan.so.1) from the host - the runtime loader is the system's, exactly
# as with the Vulkan SDK. Shipping a runtime loader (#3) solved a CI problem
# in the artifact; the smoke test now takes its runtime loader from the
# loader's build tree instead.
real_loader="$(find "$INSTALL_DIR/lib" -maxdepth 1 -name 'libvulkan.so.*' -type f)"
if [ "$(printf '%s\n' "$real_loader" | grep -c .)" -ne 1 ]; then
  echo "ERROR: expected exactly one real libvulkan.so.<version>, found:" >&2
  printf '%s\n' "$real_loader" >&2
  exit 1
fi
# Move FIRST, then clear the leftovers. The obvious order (rm the symlinks,
# then mv) is a trap: if a future Vulkan-Loader tag drops the VERSION property
# and keeps only SOVERSION 1, the real file IS libvulkan.so.1 - the
# exactly-one guard above still passes, the rm then deletes it, and the script
# dies on `mv: cannot stat`.
mv "$real_loader" "$INSTALL_DIR/lib/libvulkan.so.real"
rm -f "$INSTALL_DIR/lib/libvulkan.so" "$INSTALL_DIR/lib/libvulkan.so.1"
mv "$INSTALL_DIR/lib/libvulkan.so.real" "$INSTALL_DIR/lib/libvulkan.so"

# The loader is useless to VSG without the xcb surface entry point - a loader
# built without it links fine and then fails at window creation.
# NOT `nm ... | grep -q`: under `set -o pipefail` grep -q exits on the first
# match, nm dies of SIGPIPE with 141, and pipefail makes the whole pipeline
# fail - so the guard fires on a PERFECTLY GOOD loader. Observed, not
# theoretical: that is exactly how this guard first behaved. Capture, then
# match, so no pipe exists to break.
vk_symbols="$(nm -D --defined-only "$INSTALL_DIR/lib/libvulkan.so")"
case "$vk_symbols" in
  *vkCreateXcbSurfaceKHR*) ;;
  *) echo "ERROR: the built Vulkan loader has no XCB WSI support" >&2
     exit 1 ;;
esac

# glslang - static PIC, hidden visibility (consumers link it into shared
# objects). Same configuration as the vcpkg glslang port modeuler-ng used to
# consume: no spirv-opt (ENABLE_OPT=OFF), no standalone tools, no tests.
build glslang \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS="$OPT_FLAGS $VIS_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$OPT_FLAGS $VIS_CXX_FLAGS" \
  -DBUILD_EXTERNAL=OFF \
  -DGLSLANG_TESTS=OFF \
  -DENABLE_OPT=OFF \
  -DENABLE_GLSLANG_BINARIES=OFF

# assimp - static PIC, hidden visibility (model importers). Vendored zlib
# keeps the build hermetic on both platforms.
build assimp \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS="$OPT_FLAGS $VIS_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$OPT_FLAGS $VIS_CXX_FLAGS" \
  -DASSIMP_BUILD_ZLIB=ON \
  -DASSIMP_BUILD_TESTS=OFF \
  -DASSIMP_BUILD_ASSIMP_TOOLS=OFF \
  -DASSIMP_INSTALL_PDB=OFF \
  -DASSIMP_WARNINGS_AS_ERRORS=OFF

# VulkanSceneGraph - STATIC PIC. Windowing (xcb) and the glslang shader
# compiler are ON by default; both must survive into the artifact (checked
# below).
#
# VSG_SUPPORTS_ShaderOptimizer is pre-seeded OFF for the same reason the
# vsgXchange options below are: upstream defaults it ON and then quietly keeps
# it if find_package(SPIRV-Tools-opt) happens to succeed, so whatever is
# installed on the build host decides what ends up in the artifact. It also
# matches -DENABLE_OPT=OFF on glslang above and the vcpkg configuration this
# build replaces, neither of which has the optimizer.
build vsg \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS="$OPT_FLAGS $VIS_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$OPT_FLAGS $VIS_CXX_FLAGS" \
  -DVSG_SUPPORTS_ShaderOptimizer=OFF

# VSG only *warns* and silently disables the shader compiler when glslang is
# not found - guard against shipping a degraded build. The installed
# vsgConfig.cmake contains find_package(glslang) iff the compiler is in.
# (The upstream configs are removed from the artifact further down; at this
# point in the build they are still the most direct record of what vsg did.)
if ! grep -q "find_package(glslang" "$INSTALL_DIR/lib/cmake/vsg/vsgConfig.cmake"; then
  echo "ERROR: vsg was built WITHOUT the glslang shader compiler" >&2
  exit 1
fi

# The mirror of that check, for the optimizer. vsgConfig.cmake is generated as
#   if (@VSG_SUPPORTS_ShaderOptimizer@)
#       find_dependency(SPIRV-Tools-opt)
# so a host-detected optimizer means vsg was built against SPIRV-Tools this
# artifact does not ship. Test the generated gate line itself rather than the
# whole file, so an unrelated `if (ON)` in a future VSG config template cannot
# mask this. Also pipe-free, and here the pipe was the DANGEROUS direction:
# `grep ... | grep -q` returning 141 on SIGPIPE would have made this `if`
# false and the guard silently skip on exactly the broken artifact it exists
# to reject. `|| true` because grep exits 1 when the file has no such line at
# all, which is the healthy case and must not trip `set -e`.
spirv_gate="$(grep -B1 "find_dependency(SPIRV-Tools-opt)" \
                "$INSTALL_DIR/lib/cmake/vsg/vsgConfig.cmake" || true)"
case "$spirv_gate" in
  *"if (ON)"*)
     echo "ERROR: vsg picked up SPIRV-Tools from the build host - the artifact" >&2
     echo "       would depend on a SPIRV-Tools-opt package it does not ship" >&2
     exit 1 ;;
esac

# vsgXchange - static PIC. assimp is the only optional dependency enabled
# (matches modeuler-ng's vcpkg feature set: vsgxchange[assimp]). The other
# optional deps are pre-seeded OFF so libraries present on the build host can
# never sneak in. stbi/dds/ktx-read/gltf/3DTiles readers are built-in.
build vsgxchange \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS="$OPT_FLAGS $VIS_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$OPT_FLAGS $VIS_CXX_FLAGS" \
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

# vsgImGui - static PIC, imgui + implot compiled in from its pinned
# submodules, so the archive carries the complete ImGui/ImPlot object set.
# SHOW_DEMO_WINDOW=OFF matches the vcpkg port (ImGui::ShowDemoWindow becomes
# a no-op stub).
build vsgimgui \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS="$OPT_FLAGS $VIS_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$OPT_FLAGS $VIS_CXX_FLAGS" \
  -DSHOW_DEMO_WINDOW=OFF

# ---------------------------------------------------------------------------
# Package config: one hand-written vsgallConfig.cmake, ZERO package lookups.
#
# Upstream's per-package configs re-find Vulkan, glslang and xcb because
# upstream links them dynamically; with everything absorbed into static
# archives those lookups are pure integration cost for consumers (issue #4:
# Vulkan_ROOT/glslang_DIR plumbing, a vcpkg vulkan port, pkg-config required
# at configure time). The prefix ships exactly ONE cmake file, stating the
# link line by path, and the upstream configs are removed so nothing can
# quietly depend on them.

pick_lib() { # pick_lib <label> <candidate-file-name...> -> the one that exists
  # Candidates cover the per-config name postfixes of every upstream project
  # ("d"/"rd" from vsgMacros, "d" from assimp) so this script does not encode
  # which project applies which postfix on which platform - but a candidate
  # set matching zero or several files fails the build.
  local label="$1"; shift
  local found="" f
  for f in "$@"; do
    [ -e "$INSTALL_DIR/lib/$f" ] || continue
    if [ -n "$found" ]; then
      echo "ERROR: several archives match $label in $INSTALL_DIR/lib: $found, $f" >&2
      exit 1
    fi
    found="$f"
  done
  if [ -z "$found" ]; then
    echo "ERROR: no archive found for $label in $INSTALL_DIR/lib (tried: $*)" >&2
    exit 1
  fi
  printf '%s\n' "$found"
}

LIB_VSGXCHANGE="$(pick_lib vsgXchange libvsgXchange.a libvsgXchanged.a libvsgXchangerd.a)"
LIB_VSGIMGUI="$(pick_lib vsgImGui libvsgImGui.a libvsgImGuid.a libvsgImGuird.a)"
LIB_VSG="$(pick_lib vsg libvsg.a libvsgd.a libvsgrd.a)"
LIB_GLSLANG_LIMITS="$(pick_lib glslang-default-resource-limits \
  libglslang-default-resource-limits.a libglslang-default-resource-limitsd.a)"
LIB_GLSLANG="$(pick_lib glslang libglslang.a libglslangd.a)"
LIB_SPIRV="$(pick_lib SPIRV libSPIRV.a libSPIRVd.a)"
LIB_MACHIND="$(pick_lib MachineIndependent libMachineIndependent.a libMachineIndependentd.a)"
LIB_GENCODE="$(pick_lib GenericCodeGen libGenericCodeGen.a libGenericCodeGend.a)"
LIB_OSDEP="$(pick_lib OSDependent libOSDependent.a libOSDependentd.a)"
LIB_ASSIMP="$(pick_lib assimp libassimp.a libassimpd.a)"
LIB_ZLIB="$(pick_lib zlib libzlibstatic.a libzlibstaticd.a)"

# Drop everything package-shaped the upstream installs left behind: cmake
# package dirs (vsg, vsgXchange, vsgImGui, glslang, assimp, VulkanHeaders,
# VulkanLoader), pkg-config files, and the Vulkan XML registry (consumers
# compile against include/vulkan; nothing reads the registry).
rm -rf "$INSTALL_DIR/lib/cmake" "$INSTALL_DIR/lib/pkgconfig" \
       "$INSTALL_DIR/share/vulkan" "$INSTALL_DIR/share/cmake"
rmdir "$INSTALL_DIR/share" 2>/dev/null || true

VSGALL_CMAKE_DIR="$INSTALL_DIR/lib/cmake/vsgall"
mkdir -p "$VSGALL_CMAKE_DIR"
{
  cat <<EOF
# vsgallConfig.cmake - generated by farfield-ru/libvsg-build for
# VulkanSceneGraph $VSG_TAG ($BUILD_TYPE, Linux x64). The single supported
# entry point of this prefix:
#
#   find_package(vsgall CONFIG REQUIRED)
#   target_link_libraries(app PRIVATE vsgall::vsgall)
#
# Deliberately contains NO find_dependency/find_package/pkg_check_modules.
# Every dependency is either a static archive inside this prefix, stated
# below by path, or a plain system library name (xcb, pthread, dl) the linker
# resolves itself. The Vulkan entry is the LINK artifact (libvulkan.so); the
# runtime loader (libvulkan.so.1) comes from the host system at run time.
EOF
  printf '\nset(vsgall_VERSION "%s")\n\n' "${VSG_TAG#v}"
  cat <<'EOF'
# The version is set ABOVE this guard on purpose. Imported targets are visible
# to subdirectories, so a second find_package() in a subdirectory takes the
# early return - and anything below it, including vsgall_VERSION, would never
# run there. Setting it first makes the variable present in every scope that
# asks.
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
EOF
  for lib in "$LIB_VSGXCHANGE" "$LIB_VSGIMGUI" "$LIB_VSG" \
             "$LIB_GLSLANG_LIMITS" "$LIB_GLSLANG" "$LIB_SPIRV" \
             "$LIB_MACHIND" "$LIB_GENCODE" "$LIB_OSDEP" \
             "$LIB_ASSIMP" "$LIB_ZLIB"; do
    printf '  "${_vsgall_prefix}/lib/%s"\n' "$lib"
  done
  cat <<'EOF'
  # Vulkan by -l:FILENAME against the -L below, NOT by absolute path. CMake
  # adds the directory of any SHARED library named by path to a consumer's
  # build RPATH, and with CMAKE_INSTALL_RPATH_USE_LINK_PATH=TRUE bakes that
  # absolute build-tree path into installed binaries. A -l flag is not a path,
  # so no RPATH is derived; -l:libvulkan.so still resolves to this prefix's
  # link stub, whose SONAME (libvulkan.so.1) is what lands in DT_NEEDED and is
  # satisfied by the host loader at run time.
  "-l:libvulkan.so"
  xcb
  pthread
  dl)

# The linker-level half of symbol hiding. The archives are compiled with
# -fvisibility=hidden, but assimp marks its public API with an explicit
# visibility attribute that OVERRIDES the compile flag, so a consumer's
# shared object would re-export aiGetMaterial* and friends. --exclude-libs
# localizes every symbol drawn from these archives when a consumer links a
# shared object, whatever the objects' own visibility says. Scoped to these
# archives by name - a consumer's other static libraries are not affected.
set_property(TARGET vsgall::vsgall PROPERTY INTERFACE_LINK_OPTIONS
  # -L as a link OPTION, not INTERFACE_LINK_DIRECTORIES: CMake derives a build
  # RUNPATH from link directories (verified - a consumer got the prefix baked
  # in), but link options are opaque strings it does not inspect. This is what
  # keeps "no rpath handling downstream" true.
  "-L${_vsgall_prefix}/lib"
EOF
  for lib in "$LIB_VSGXCHANGE" "$LIB_VSGIMGUI" "$LIB_VSG" \
             "$LIB_GLSLANG_LIMITS" "$LIB_GLSLANG" "$LIB_SPIRV" \
             "$LIB_MACHIND" "$LIB_GENCODE" "$LIB_OSDEP" \
             "$LIB_ASSIMP" "$LIB_ZLIB"; do
    printf '  "LINKER:--exclude-libs,%s"\n' "$lib"
  done
  cat <<'EOF'
)

unset(_vsgall_prefix)
EOF
} > "$VSGALL_CMAKE_DIR/vsgallConfig.cmake"

# find_package(vsgall 1.1.15 CONFIG REQUIRED) - the entirely ordinary versioned
# form - fails without this file, and fails MISLEADINGLY: CMake reports "could
# not find a configuration file compatible with requested version", which reads
# as "package not found" rather than "version mismatch". AnyNewerVersion
# semantics: the prefix satisfies any request at or below what it ships.
cat > "$VSGALL_CMAKE_DIR/vsgallConfigVersion.cmake" <<EOF
# vsgallConfigVersion.cmake - generated by farfield-ru/libvsg-build.
set(PACKAGE_VERSION "${VSG_TAG#v}")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOF

# Lock the config's defining property in: no package lookups, ever. Comments
# are stripped first - the config's own header legitimately NAMES the banned
# commands while promising their absence.
config_code="$(sed 's/#.*//' "$VSGALL_CMAKE_DIR/vsgallConfig.cmake")"
case "$config_code" in
  *find_dependency*|*find_package*|*pkg_check_modules*)
    echo "ERROR: vsgallConfig.cmake grew a package lookup" >&2
    exit 1 ;;
esac

# And the artifact-wide version of the same promise: the config and its
# version file are the ONLY cmake files the prefix ships.
shipped_cmake="$(find "$INSTALL_DIR" -name '*.cmake' | sort)"
expected_cmake="$(printf '%s\n%s\n' \
  "$VSGALL_CMAKE_DIR/vsgallConfig.cmake" \
  "$VSGALL_CMAKE_DIR/vsgallConfigVersion.cmake" | sort)"
if [ "$shipped_cmake" != "$expected_cmake" ]; then
  echo "ERROR: unexpected cmake files in the prefix:" >&2
  printf '%s\n' "$shipped_cmake" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Consume the prefix the way a downstream project does - find_package(vsgall),
# compile, link, run - before packaging it. Building the libraries proves they
# compile; only this proves the INSTALL is usable.
#
# SCRUBBED environment: env -i means no VULKAN_SDK, no vcpkg variables, no
# CMAKE_PREFIX_PATH, no inherited LD_LIBRARY_PATH - so anything the prefix
# fails to provide surfaces HERE instead of in a consumer. (Issue #4: round 1
# of the consumer integration found three defects of exactly the class "the
# prefix needs something the producer never checked for".)
# The scrub must not also scrub away the toolchain. A hardcoded
# PATH=/usr/local/bin:/usr/bin:/bin breaks every host whose cmake/ninja/compiler
# lives elsewhere - a Kitware tarball in /opt, a snap, ~/.local/bin, nix,
# Linuxbrew - and it breaks it AFTER a 20-40 minute build, with an
# `env: 'cmake': No such file or directory` that reads like a broken prefix.
# Keep the directories the tools were actually discovered in.
SMOKE_BUILD="$WORK/build-smoke-$BUILD_TYPE"
scrub_path="/usr/local/bin:/usr/bin:/bin"
for tool in cmake ninja "${CC:-cc}" "${CXX:-c++}"; do
  tool_path="$(command -v "$tool" 2>/dev/null)" || continue
  tool_dir="$(dirname "$tool_path")"
  case ":$scrub_path:" in
    *":$tool_dir:"*) ;;
    *) scrub_path="$tool_dir:$scrub_path" ;;
  esac
done
SCRUB=(env -i "PATH=$scrub_path")
rm -rf "$SMOKE_BUILD"
"${SCRUB[@]}" cmake -S "$ROOT/scripts/smoke" -B "$SMOKE_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_PREFIX_PATH="$INSTALL_DIR"
"${SCRUB[@]}" cmake --build "$SMOKE_BUILD"

# The smoke SHARED library proves two properties of the archives that the
# executable cannot: they are PIC (this link fails otherwise), and they are
# visibility-hidden - absorbed vsg/glslang/assimp/zlib symbols must NOT
# resurface as dynamic exports of a consumer's shared object.
# Assert the export set EXACTLY, rather than probing for a few known-bad names.
# A substring denylist (aiGetMaterial / inflate / glslang) only ever finds what
# it was told to look for. Measured: relinking this same shared library without
# --exclude-libs leaks 62 dynamic exports - STL template instantiations,
# spv:: and Vk* types - of which exactly ONE matches any denylisted substring,
# and only incidentally, as "glslang" inside a mangled template argument. The
# other 61 are invisible to it, as is every zlib C entry point (adler32,
# crc32, deflate, gz*) issue #4 cites. shared.cpp exports exactly one symbol,
# so "the dynamic export set is exactly that symbol" is both strictly stronger
# and no more expensive. Linker-generated entries are filtered, not enumerated.
#
# STRONG symbols only (nm types T/D/B/R/i, not W/V/u). At -O0 the consumer's
# OWN translation unit emits every used vsg/STL inline and template as an
# out-of-line WEAK definition with default visibility - shared.cpp is
# deliberately compiled like a naive consumer, and --exclude-libs governs
# archives, not the consumer's objects - so the Debug smoke library
# legitimately exports ~190 weak instantiations (ref_ptr ctors, std::forward)
# that Release inlines away. Those are the consumer's own ODR-mergeable
# duplicates, not absorbed-archive leaks; every leak this guard exists for
# (aiGetMaterialColor, adler32, spv::*) arrives as a strong symbol from an
# archive member. A single awk stage does both filters: no early-exit pipe
# stage, and an empty result still reaches the comparison and its message.
smoke_exports="$(nm -D --defined-only --format=posix "$SMOKE_BUILD/libvsg_smoke_shared.so" \
                 | awk '$2 ~ /^[TDBRi]$/ && $1 !~ /^(_init|_fini|__bss_start|_edata|_end)$/ {print $1}' \
                 | sort)"
if [ "$smoke_exports" != "vsg_smoke_shared_touch" ]; then
  echo "ERROR: the smoke shared library's STRONG dynamic exports are not exactly its" >&2
  echo "       own marker symbol - absorbed dependencies leaked, or the marker is gone." >&2
  echo "       Expected: vsg_smoke_shared_touch" >&2
  echo "       Got:" >&2
  printf '%s\n' "$smoke_exports" | sed 's/^/         /' >&2
  exit 1
fi

# Running also needs a RUNTIME Vulkan loader, which the prefix deliberately
# does not ship. Take the one just built: pointing LD_LIBRARY_PATH at the
# loader's BUILD tree (not at the prefix) keeps "the artifact needs only
# system libraries at run time" honest, without requiring libvulkan1 on the
# build host. Runtime-loader provisioning belongs to the build environment,
# not to the artifact.
LOADER_RUNTIME_DIR="$WORK/build-vulkan-loader-$BUILD_TYPE/loader"
if [ ! -e "$LOADER_RUNTIME_DIR/libvulkan.so.1" ]; then
  echo "ERROR: no runtime loader at $LOADER_RUNTIME_DIR to run the smoke test with" >&2
  exit 1
fi
"${SCRUB[@]}" LD_LIBRARY_PATH="$LOADER_RUNTIME_DIR" "$SMOKE_BUILD/vsg_smoke"

ARCHIVE="$DIST_DIR/vsg-$VSG_TAG-linux-x64-$BUILD_TYPE.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK/install" "vsg-$BUILD_TYPE"
echo "Packaged: $ARCHIVE"
