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
# OpenBW is header-only template code; unoptimized it is several times
# slower, which shows up as stutter even in a debug app build.
if(NOT MSVC)
	target_compile_options(bwbridge PRIVATE -O2)
endif()

# The gameplay smoke test only builds when this directory is configured on
# its own (cd engine/bridge && cmake ...), not as part of the app build.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
	add_executable(bridge_smoke_test tests/bridge_smoke_test.c)
	target_include_directories(bridge_smoke_test PRIVATE include)
	target_link_libraries(bridge_smoke_test PRIVATE bwbridge)
	set_target_properties(bridge_smoke_test PROPERTIES LINKER_LANGUAGE CXX)
	target_compile_definitions(bridge_smoke_test PRIVATE BOTS_DIR="${CMAKE_CURRENT_LIST_DIR}/../../assets/bots")
	# The bot profile language on its own (no game data).
	add_executable(botscript_test tests/botscript_test.cpp)
	target_include_directories(botscript_test PRIVATE src ${OPENBW_DIR})
	target_compile_definitions(botscript_test PRIVATE BOTS_DIR="${CMAKE_CURRENT_LIST_DIR}/../../assets/bots")
endif()
