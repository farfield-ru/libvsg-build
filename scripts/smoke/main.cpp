// Touches all three libraries without needing a GPU, a display or a Vulkan
// device, so it runs on any build agent:
//   - vsg      scene-graph objects + the intrusive ref_ptr machinery
//   - vsgXchange  the reader/writer set is registered AND the absorbed assimp
//                 importers actually answer (static archives can silently
//                 drop registration objects - this is the regression guard)
//   - vsgImGui    calling into the ImGui compiled into the archive
// The umbrella headers on purpose: a smoke test should fail if ANY installed
// header is missing or inconsistent, not just the handful this file names.
#include <vsg/all.h>
#include <vsgXchange/all.h>
#include <vsgImGui/imgui.h>

#include <cstdio>

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

    std::printf("smoke: ok (children=%zu, readers=%zu, extensions=%zu)\n",
                group->children.size(), options->readerWriters.size(),
                features.extensionFeatureMap.size());
    return 0;
}
