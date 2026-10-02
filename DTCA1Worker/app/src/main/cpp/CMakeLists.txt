# Phase 6 native runtime integration.
#
# Builds the ONE shared library that contains llama.cpp and the JNI bridge to it.
#
# ADR-012 §2: this is the runtime adapter boundary. Everything above it sees a JSON contract.
# ADR-012 §11: CPU only. GGML_VULKAN is explicitly OFF so a GPU path cannot be enabled by
# accident, and n_gpu_layers is forced to 0 in llama_jni.cpp.
#
# The prebuilt llama.cpp static libraries are consumed rather than rebuilt here, so that the
# exact upstream commit built for this project is a recorded artifact rather than something
# that silently varies between builds.

cmake_minimum_required(VERSION 3.22.1)
project(pdllama CXX)

set(LLAMA_CPP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third_party/llama.cpp"
    CACHE PATH "llama.cpp source tree")
set(LLAMA_CPP_BUILD "${LLAMA_CPP_ROOT}/build-android"
    CACHE PATH "llama.cpp Android build directory")

if(NOT EXISTS "${LLAMA_CPP_BUILD}/src/libllama.a")
    message(FATAL_ERROR
        "llama.cpp Android static libraries not found at ${LLAMA_CPP_BUILD}.\n"
        "Build them first:\n"
        "  cmake -B build-android -G \"Unix Makefiles\" \\\n"
        "    -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \\\n"
        "    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-31 -DANDROID_STL=c++_static \\\n"
        "    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \\\n"
        "    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \\\n"
        "    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF \\\n"
        "    -DGGML_OPENMP=OFF -DGGML_VULKAN=OFF -DGGML_LLAMAFILE=OFF\n"
        "  cmake --build build-android --target llama ggml -j8")
endif()

add_library(pdllama SHARED llama_jni.cpp)

target_include_directories(pdllama PRIVATE "${LLAMA_CPP_ROOT}/include")
target_include_directories(pdllama PRIVATE "${LLAMA_CPP_ROOT}/ggml/include")

# Whole-archive: ggml registers its CPU backend through static initialisers, which a plain
# static link would drop, producing "no backend" at runtime rather than a link error.
target_link_options(pdllama PRIVATE
    "-Wl,--whole-archive"
    "${LLAMA_CPP_BUILD}/src/libllama.a"
    "${LLAMA_CPP_BUILD}/ggml/src/libggml.a"
    "${LLAMA_CPP_BUILD}/ggml/src/libggml-cpu.a"
    "${LLAMA_CPP_BUILD}/ggml/src/libggml-base.a"
    "-Wl,--no-whole-archive")

find_library(LOG_LIB log)
target_link_libraries(pdllama ${LOG_LIB} android)

target_compile_options(pdllama PRIVATE -O3 -fexceptions -frtti -DNDEBUG)
