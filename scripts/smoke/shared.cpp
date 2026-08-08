// Compiled into vsg_smoke_shared (a SHARED library) on Linux. The exported
// function pulls vsg and the absorbed assimp (via vsgXchange::all) into the
// link, so the build script can assert on the resulting dynamic symbol
// table: only this marker may be exported - none of the absorbed
// dependencies' symbols (aiGetMaterial*, inflate*, glslang::*) may leak out
// of a consumer's shared object.
#include <vsg/all.h>
#include <vsgXchange/all.h>

extern "C" int vsg_smoke_shared_touch()
{
    auto options = vsg::Options::create(vsgXchange::all::create());
    return static_cast<int>(options->readerWriters.size());
}
