#!/bin/bash
# Builds llama.cpp (pinned) as static libraries with Metal into app/Vendor/llama, for the app to link.
# Needs git and cmake; without cmake installed it runs cmake through uv.
set -euo pipefail
TAG="${LLAMA_TAG:-v1.0.0}"
here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/app/Vendor/llama-src"
out="$here/app/Vendor/llama"
cmake_bin=(cmake); command -v cmake >/dev/null || cmake_bin=(uvx cmake)

if [ ! -d "$src/.git" ]; then
    rm -rf "$src"
    git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$src"
fi
"${cmake_bin[@]}" -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
"${cmake_bin[@]}" --build "$src/build" --config Release --target llama -j 8 >/dev/null
rm -rf "$out"; mkdir -p "$out/lib" "$out/include"
find "$src/build" -name "*.a" -exec cp {} "$out/lib/" \;
cp "$src/include/llama.h" "$src"/ggml/include/*.h "$out/include/"
echo "$TAG" > "$out/TAG"
rm -rf "$src"        # only the libraries and headers are needed from here on
ls "$out/lib"
