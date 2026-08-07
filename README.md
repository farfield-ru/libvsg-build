# libvsg-build

Build scripts and CI pipeline that compile the
[VulkanSceneGraph](https://github.com/vsg-dev/VulkanSceneGraph) stack as
**shared libraries** for **Linux (x64)** and **Windows (x64, MSVC)** and publish
the binaries as GitHub Release assets. Companion to
[libocct-build](https://github.com/farfield-ru/libocct-build), for the same
consumer ([modeuler-ng](https://github.com/farfield-ru/modeuler-ng)).

## What is built

One install prefix per configuration (`vsg-<BuildType>/`) containing:

| Component | Tag | Linkage | Why |
|---|---|---|---|
| [VulkanSceneGraph](https://github.com/vsg-dev/VulkanSceneGraph) | `v1.1.15` | **shared** | Core scene graph / Vulkan renderer |
| [vsgXchange](https://github.com/vsg-dev/vsgXchange) | `v1.1.13` | **shared** | Asset readers/writers (`vsgXchange::all`) |
| [vsgImGui](https://github.com/vsg-dev/vsgImGui) | `v0.7.0` | **shared** | Dear ImGui + ImPlot integration (imgui/implot compiled in from its pinned submodules) |
| [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) | `vulkan-sdk-1.4.341.0` | headers | Satisfies `find_package(Vulkan)` for vsg **and for consumers** |
| [Vulkan-Loader](https://github.com/KhronosGroup/Vulkan-Loader) | `vulkan-sdk-1.4.341.0` | **shared** | The runtime loader (`libvulkan.so.1` / `vulkan-1.dll`) |
| [glslang](https://github.com/KhronosGroup/glslang) | `16.3.0` | static (PIC), absorbed into vsg | Runtime GLSL→SPIR-V compiler (`VSG_SUPPORTS_ShaderCompiler`) |
| [assimp](https://github.com/assimp/assimp) | `v6.0.4` | static (PIC), absorbed into vsgXchange | Model importers for the vsgXchange assimp reader |

Tags are pinned in `scripts/build.*` and `.github/workflows/build.yml`, and
match the versions modeuler-ng previously received from vcpkg (baseline
`9e53836`).

- Configurations: `Release`, `Debug`, `RelWithDebInfo` (per-config library
  name postfixes `d` / `rd` come from upstream `vsgMacros.cmake`).
- On Windows the MSVC runtime of the app must match the libraries, so pick
  the archive matching your `CMAKE_BUILD_TYPE`; on Linux the Release archive
  links cleanly into any app build type.

### Feature choices (parity with modeuler-ng's vcpkg manifest)

- **vsg**: windowing ON (xcb on Linux, native Win32 on Windows), shader
  compiler ON (glslang), shader *optimizer* **pre-seeded OFF** (no
  SPIRV-Tools, same as vcpkg's plain `glslang` dependency). Upstream defaults
  `VSG_SUPPORTS_ShaderOptimizer` ON and keeps it whenever
  `find_package(SPIRV-Tools-opt)` succeeds, so on a host with a Vulkan SDK it
  would otherwise be enabled by accident — and the generated `vsgConfig.cmake`
  would then make **every consumer** need a `SPIRV-Tools-opt` package this
  artifact does not ship. The build **fails** if VSG silently drops the shader
  compiler (it only warns when glslang is missing) or if the optimizer sneaks
  back in.
- **vsgXchange**: `assimp` reader ON — every other optional dependency
  (freetype, curl, GDAL, OpenEXR, KTX, draco, OSG) is pre-seeded OFF so a
  library found on the build host can never leak into the artifact. The
  dependency-free built-in readers (stbi, dds, ktx-read, glTF, 3DTiles, cpp,
  bin) are always present. The build fails if assimp is not picked up
  (vsgXchange would otherwise silently ship a stub reader).
- **vsgImGui**: `SHOW_DEMO_WINDOW=OFF` (`ImGui::ShowDemoWindow` is a stub),
  matching the vcpkg port.

### No Vulkan SDK required

Vulkan is built from pinned Khronos tags and installed into the prefix, so the
artifact satisfies `find_package(Vulkan)` on its own and ships the runtime
loader. Consumers need no SDK, and neither does this repo's CI — the LunarG
installer, the SDK cache and the System32 `vulkan-1.dll` shuffle it needed to
run the smoke test are all gone.

On Linux the loader is built with **XCB WSI only**, matching exactly what the
previously-consumed loader exported (`vkCreateXcbSurfaceKHR` +
`vkCreateDisplayPlaneSurfaceKHR`; no Xlib, no Wayland). VSG creates its surface
from an `xcb_window_t`, and enabling Xlib would pull an xrandr dev package in
for a surface type nothing creates. Windows uses the Win32 WSI default.

What the artifact still expects from the host on Linux: `libxcb` (and its
`xcb.pc`, which `vsgConfig.cmake` checks at configure time) plus the usual C++
runtime. Bundling libxcb was considered and rejected — `libX11` links the
system one, so a second copy would put two xcb instances in one process.

### Consumer smoke test

Every configuration builds `scripts/smoke/` against the finished install
prefix — `find_package` for all three packages, compile, link, run — before
the archive is packaged, with `CMAKE_PREFIX_PATH` set to the install dir
alone. Compiling the libraries only proves they build; this proves the
**install** is consumable, which is the property downstream projects actually
depend on. On Windows it doubles as the ImGui re-export check: a `vsgImGui`
DLL that does not re-export the ImGui API fails to link it with LNK2019.

### Why shared vsgImGui works here (unlike vcpkg's)

vcpkg devendors imgui/implot into separate **static** libraries, so a dynamic
`vsgImGui.dll` re-exports only the ImGui symbols it happens to use itself —
consumers calling any other ImGui function hit LNK2019, which is why
modeuler-ng needed an overlay triplet forcing the whole ImGui stack static
(see modeuler-ng `docs/VSG.md` §9).

Upstream vsgImGui instead compiles its pinned imgui/implot **submodules
directly into the library** with
`IMGUI_USER_CONFIG=<vsgImGui/Export.h>`, which defines
`IMGUI_API`/`IMPLOT_API` as `__declspec(dllexport)` while building — the DLL
exports the **full** ImGui/ImPlot API and consumers can call anything.
Consumers include `<vsgImGui/imgui.h>` (installed with the package), not a
separate imgui package.

## Consuming

Point `CMAKE_PREFIX_PATH` at the extracted prefix; then

```cmake
find_package(vsg CONFIG REQUIRED)        # target vsg::vsg
find_package(vsgXchange CONFIG REQUIRED) # target vsgXchange::vsgXchange
find_package(vsgImGui CONFIG REQUIRED)   # target vsgImGui::vsgImGui
```

All transitive CMake packages resolve inside the prefix itself (glslang's and
assimp's configs are installed alongside). Configure-time host requirements:

- **Vulkan**: `vsgConfig.cmake` does `find_package(Vulkan REQUIRED)` — Vulkan
  SDK on Windows, `libvulkan-dev` on Linux.
- **Linux only**: `pkg-config` + `libxcb1-dev` (`vsgConfig.cmake` runs
  `pkg_check_modules(xcb REQUIRED)` because windowing was built in).

Runtime layout: Linux `lib/*.so`; Windows DLLs in `bin/`, import libraries in
`lib/`. `bin/vsgconv` (vsgXchange's converter tool) doubles as a smoke test
that the shared libraries link and load.

## Optimization

- Linux Release adds `-march=x86-64-v2` (requires an SSE4.2-era CPU, roughly
  2009 or newer) — same distribution baseline as libocct-build.
- No LTO: upstream ships no LTO profile for these libraries (unlike OCCT's
  `BUILD_OPT_PROFILE=Production`), and the expected win is small relative to
  the toolchain risk.

## Patches

`patches/<component>/*.patch` (component ∈ `glslang`, `assimp`, `vsg`,
`vsgxchange`, `vsgimgui`) are applied with `git apply` after cloning the
upstream tag. Currently empty.

## Local build

Linux (needs cmake, ninja, git, pkg-config, libxcb1-dev, libvulkan-dev):

```sh
./scripts/build.sh Release        # or Debug / RelWithDebInfo
```

Windows (from an *x64 Native Tools* developer prompt, requires Ninja and the
Vulkan SDK):

```powershell
.\scripts\build.ps1 -BuildType Release
```

The script clones the pinned tags, builds in dependency order
(glslang → assimp → vsg → vsgXchange → vsgImGui), installs into
`_work/install/vsg-<BuildType>/` and packages an archive into `_work/dist/`.

## CI

`.github/workflows/build.yml` runs a 2 (OS) × 3 (build type) matrix on every
push to `main` (and on manual dispatch), uploads each build as a workflow
artifact, and then creates/updates the `vsg-<VSG_TAG>` GitHub Release with all
six archives.

Windows builds are pinned to `windows-2022` (VS 2022, MSVC 14.4x): the
VS 2026 toolset currently on `windows-latest` (MSVC 14.51) has a documented
known issue — *"cl.exe hangs compiling some source files"* — and
deterministically hangs on assimp's vendored contrib sources. The MSVC 14.x
ABI is stable, so VS 2026 consumers link these DLLs without issues. Move back
to `windows-latest` once the MSVC fix ships.

## Upgrading

Change the tags in `.github/workflows/build.yml` (and the defaults in
`scripts/build.sh` / `scripts/build.ps1`), push to `main`, and a new release
`vsg-<tag>` is produced. Mind upstream's cross-version constraints:
vsgXchange `v1.1.13` requires vsg ≥ 1.1.14, vsgImGui `v0.7.0` requires
vsg ≥ 1.1.10, vsgXchange requires assimp ≥ 5.1.
