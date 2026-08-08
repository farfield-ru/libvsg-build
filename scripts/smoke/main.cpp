// Touches all three libraries without needing a GPU, a display or a Vulkan
// device, so it runs on any build agent:
//   - vsg      scene-graph objects + the intrusive ref_ptr machinery
//   - vsgXchange  the reader/writer set is registered AND the absorbed assimp
//                 importers actually answer (static archives can silently
//                 drop registration objects - this is the regression guard)
//   - vsgImGui    calling into the ImGui compiled into the archive
//   - glslang     the runtime shader compiler actually compiles GLSL -> SPIR-V
//   - xcb         the windowing objects link (creating one is allowed to fail)
// The umbrella headers on purpose: a smoke test should fail if ANY installed
// header is missing or inconsistent, not just the handful this file names.
#include <vsg/all.h>
#include <vsgXchange/all.h>
#include <vsgImGui/imgui.h>

#include <cstdio>
#include <exception>

int main()
{
    auto group = vsg::Group::create();
    group->addChild(vsg::MatrixTransform::create());

    auto options = vsg::Options::create(vsgXchange::all::create());
    if (options->readerWriters.empty())
    {
        std::fprintf(stderr, "smoke: vsgXchange registered no readers\n");
        return 1;
    }

    // Deeper than "some readers exist": ask the registered readers what they
    // support and require a format only the absorbed assimp can provide. This
    // walks assimp's live importer registry, so it fails if static linking
    // dropped the importers or their registration.
    vsg::ReaderWriter::Features features;
    vsg::getFeatures(options, features);
    if (features.extensionFeatureMap.count(".obj") == 0)
    {
        std::fprintf(stderr, "smoke: assimp importers missing (.obj is not readable)\n");
        return 1;
    }

    const ImGuiContext* ctx = ImGui::GetCurrentContext();
    (void)ctx;

    // The runtime shader compiler is the whole reason glslang is in this
    // artifact, and nothing above pulls a single glslang object - so the five
    // glslang archives and their order in the generated link line were never
    // validated. Compile a trivial shader: this walks GLSL -> SPIR-V through
    // the absorbed glslang and needs no GPU, no device and no display.
    auto vertex = vsg::ShaderStage::create(VK_SHADER_STAGE_VERTEX_BIT, "main", R"(
#version 450
void main() { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); }
)");
    auto compiler = vsg::ShaderCompiler::create();
    if (!compiler->compile(vertex))
    {
        std::fprintf(stderr, "smoke: glslang did not compile a trivial shader\n");
        return 1;
    }
    if (vertex->module->code.empty())
    {
        std::fprintf(stderr, "smoke: shader compiled but produced no SPIR-V\n");
        return 1;
    }

    // Same gap for xcb: nothing above references the windowing objects, so the
    // `xcb` entry on the link line was never proven sufficient. Creating a
    // window is EXPECTED to fail here - build agents have no display - but the
    // call forces those objects to link, which is what is being tested. Only
    // an unresolved-symbol failure would show up, and that shows up at link
    // time, not here.
    try
    {
        auto traits = vsg::WindowTraits::create();
        traits->windowTitle = "vsg_smoke";
        traits->width = 16;
        traits->height = 16;
        auto window = vsg::Window::create(traits);
        if (window) std::printf("smoke: window created (display available)\n");
    }
    // No display / no ICD on the build agent. Expected; the link is proven.
    // BOTH clauses are needed: vsg::Exception is a plain struct that does NOT
    // derive from std::exception, so neither catch subsumes the other. (Caught
    // the hard way - catching only std::exception here reaches std::terminate
    // on a headless agent, which is precisely the false failure this handler
    // exists to prevent.) What a machine without a display throws is platform-
    // and driver-specific, and this is a LINK test: failing the build over the
    // exception's type would defeat its purpose.
    catch (const vsg::Exception&)
    {
    }
    catch (const std::exception&)
    {
    }

    std::printf("smoke: ok (children=%zu, readers=%zu, extensions=%zu)\n",
                group->children.size(), options->readerWriters.size(),
                features.extensionFeatureMap.size());
    return 0;
}
