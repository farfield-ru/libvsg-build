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
  compiler ON (glslang), shader *optimizer* OFF (no SPIRV-Tools, same as
  vcpkg's plain `glslang` dependency). The build **fails** if VSG silently
  drops the shader compiler (it only warns when glslang is missing).
- **vsgXchange**: `assimp` reader ON — every other optional dependency
  (freetype, curl, GDAL, OpenEXR, KTX, draco, OSG) is pre-seeded OFF so a
  library found on the build host can never leak into the artifact. The
  dependency-free built-in readers (stbi, dds, ktx-read, glTF, 3DTiles, cpp,
  bin) are always present. The build fails if assimp is not picked up
  (vsgXchange would otherwise silently ship a stub reader).
- **vsgImGui**: `SHOW_DEMO_WINDOW=OFF` (`ImGui::ShowDemoWindow` is a stub),
  matching the vcpkg port.

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

## Upgrading

Change the tags in `.github/workflows/build.yml` (and the defaults in
`scripts/build.sh` / `scripts/build.ps1`), push to `main`, and a new release
`vsg-<tag>` is produced. Mind upstream's cross-version constraints:
vsgXchange `v1.1.13` requires vsg ≥ 1.1.14, vsgImGui `v0.7.0` requires
vsg ≥ 1.1.10, vsgXchange requires assimp ≥ 5.1.
