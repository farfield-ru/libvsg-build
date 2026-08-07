# Consumer smoke test: proves the freshly installed prefix is actually usable
# through find_package, which is the one thing building the libraries does not
# check. Configured against the install dir alone, exactly as modeuler-ng
# consumes it.
cmake_minimum_required(VERSION 3.22)
project(vsg_smoke CXX)
set(CMAKE_CXX_STANDARD 17)

find_package(vsg CONFIG REQUIRED)
find_package(vsgXchange CONFIG REQUIRED)
find_package(vsgImGui CONFIG REQUIRED)

message(STATUS "smoke: vsg ${vsg_VERSION}, vsgXchange ${vsgXchange_VERSION}, vsgImGui ${vsgImGui_VERSION}")

add_executable(vsg_smoke main.cpp)
target_link_libraries(vsg_smoke PRIVATE vsg::vsg vsgXchange::vsgXchange vsgImGui::vsgImGui)
