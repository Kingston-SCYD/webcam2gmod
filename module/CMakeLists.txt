cmake_minimum_required(VERSION 3.10)
project(gmod-webcam LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_subdirectory(gmod-headers/include)

# Client module
add_library(webcam SHARED module.cpp)
target_include_directories(webcam PRIVATE vendor)
target_link_libraries(webcam PRIVATE gmod-module-base)
set_gmod_suffix_prefix(webcam)
set_target_properties(webcam PROPERTIES PREFIX "gmcl_")

# Server module
add_library(webcam_srv SHARED server_module.cpp)
target_include_directories(webcam_srv PRIVATE vendor)
target_link_libraries(webcam_srv PRIVATE gmod-module-base)
set_gmod_suffix_prefix(webcam_srv)
# Rename output to "webcam" with gmsv_ prefix
set_target_properties(webcam_srv PROPERTIES OUTPUT_NAME "webcam")

if(WIN32)
    target_link_libraries(webcam PRIVATE ws2_32 -static-libgcc -static-libstdc++)
    target_link_options(webcam PRIVATE -static-libgcc -static-libstdc++ -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive)
    target_link_libraries(webcam_srv PRIVATE ws2_32 -static-libgcc -static-libstdc++)
    target_link_options(webcam_srv PRIVATE -static-libgcc -static-libstdc++ -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive)
endif()
