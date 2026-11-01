cmake_minimum_required(VERSION 3.22)
project(margin_native C CXX)

include(FetchContent)

# Android has no prebuilt llama.cpp like Vendor/ios, so it's built from a pinned source release.
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
# Android devices range from old ARMv8.0 cores to ones with fast matrix instructions, so ggml picks at run time.
set(GGML_BACKEND_DL ON CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    llama
    URL https://github.com/ggml-org/llama.cpp/archive/refs/tags/v0.8.0.tar.gz
    URL_HASH SHA256=51b1e025d7b12e83fa55736e65bc254acd9d23e49f546be7531368fef82210ee
)
FetchContent_MakeAvailable(llama)

# The bridge the iPad uses, unchanged, reached through the same <llama/llama.h> path as its framework.
set(BRIDGE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../Margin)
set(HEADER_DIR ${CMAKE_CURRENT_BINARY_DIR}/headers)
file(MAKE_DIRECTORY ${HEADER_DIR}/llama)
file(WRITE ${HEADER_DIR}/llama/llama.h "#include \"${llama_SOURCE_DIR}/include/llama.h\"\n")

add_library(margin_llm SHARED ${BRIDGE_DIR}/LlamaEngine.c jni.c)
target_include_directories(margin_llm PRIVATE ${HEADER_DIR} ${BRIDGE_DIR})
target_link_libraries(margin_llm PRIVATE llama ggml log)
# Android 15 devices can use 16 KB memory pages.
target_link_options(margin_llm PRIVATE "-Wl,-z,max-page-size=16384")
# Nothing links to the CPU variants, since ggml opens them at run time, so the build has to be told to make them.
add_dependencies(margin_llm
    ggml-cpu-android_armv8.0_1
    ggml-cpu-android_armv8.2_1
    ggml-cpu-android_armv8.2_2
    ggml-cpu-android_armv8.6_1
    ggml-cpu-android_armv9.0_1
    ggml-cpu-android_armv9.2_1
    ggml-cpu-android_armv9.2_2)
