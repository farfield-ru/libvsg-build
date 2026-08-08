# Consumer smoke test: proves the freshly installed prefix is actually usable
# through find_package, which is the one thing building the libraries does not
# check. Configured against the install dir alone, in a scrubbed environment,
# exactly as modeuler-ng consumes it: ONE find_package, ONE target, nothing
# else to find anywhere.
cmake_minimum_required(VERSION 3.22)
project(vsg_smoke CXX)
set(CMAKE_CXX_STANDARD 17)

find_package(vsgall CONFIG REQUIRED)

message(STATUS "smoke: vsgall ${vsgall_VERSION}")

add_executable(vsg_smoke main.cpp)
target_link_libraries(vsg_smoke PRIVATE vsgall::vsgall)

if(UNIX)
    # A shared library consumer, because that is what modeuler-ng builds and
    # what an executable cannot exercise: linking the static archives into a
    # shared object requires them to be PIC (the link fails otherwise), and
    # the build script then checks its dynamic exports to prove the archives'
    # hidden visibility held - absorbed assimp/zlib/glslang symbols must not
    # become exports of a consumer's library.
    add_library(vsg_smoke_shared SHARED shared.cpp)
    target_link_libraries(vsg_smoke_shared PRIVATE vsgall::vsgall)
endif()
