cmake_minimum_required(VERSION 3.18)
project(sim_smoke_test CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(sim_smoke_test main.cpp)
target_include_directories(sim_smoke_test PRIVATE ${CMAKE_CURRENT_LIST_DIR}/../../vendor/openbw)
