cmake_minimum_required(VERSION 3.18)
project(bwbridge C CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(OPENBW_DIR "${CMAKE_CURRENT_LIST_DIR}/../vendor/openbw")

add_library(bwbridge SHARED
	src/bw_bridge.cpp
)
target_include_directories(bwbridge PUBLIC
	${CMAKE_CURRENT_LIST_DIR}/include
)
target_include_directories(bwbridge PRIVATE
	${OPENBW_DIR}
)

# Phase 1's sim_smoke_test proved the vendored core builds standalone against
# real game data; this target is the only place that core is wrapped in a
# plain-C API. See engine/bridge/tests/bridge_smoke_test.c for an end-to-end
# check that the extern "C" boundary itself is genuinely C-callable (not just
# C++ code that happens to compile under extern "C").
add_executable(bridge_smoke_test tests/bridge_smoke_test.c)
target_include_directories(bridge_smoke_test PRIVATE include)
target_link_libraries(bridge_smoke_test PRIVATE bwbridge)
set_target_properties(bridge_smoke_test PROPERTIES LINKER_LANGUAGE CXX)
