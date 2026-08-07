// Touches all three libraries without needing a GPU, a display or a Vulkan
// device, so it runs on any build agent:
//   - vsg      scene-graph objects + the intrusive ref_ptr machinery
//   - vsgXchange  the reader/writer set is registered (a link-time and a
//                 static-initialisation check, since vsgXchange::all pulls in
//                 the absorbed assimp)
//   - vsgImGui    the header the shared Windows build must export ImGui from
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

    // Calling into ImGui is the point on Windows: a shared vsgImGui that does
    // not re-export the ImGui API fails to LINK here (LNK2019) rather than
    // failing in a downstream consumer.
    const ImGuiContext* ctx = ImGui::GetCurrentContext();
    (void)ctx;

    std::printf("smoke: ok (children=%zu, readers=%zu)\n",
                group->children.size(), options->readerWriters.size());
    return 0;
}
