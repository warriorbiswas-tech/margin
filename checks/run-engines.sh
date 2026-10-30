#!/bin/sh
# Usage: checks/run-engines.sh <models folder> <work folder>
# The models folder holds Qwen3-1.7B-Q4_K_M.gguf and ggml-base.en.bin.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
work=$2
mkdir -p "$work"
clang -c "$root/Margin/LlamaEngine.c" -F "$root/Vendor/macos" -o "$work/llama.o"
clang -c "$root/Margin/WhisperEngine.c" -F "$root/Vendor/macos" -o "$work/whisper.o"
mkdir -p "$work/src"
cp "$root/checks/engines.swift" "$work/src/main.swift"
swiftc -swift-version 5 -import-objc-header "$root/Margin/Engines.h" \
  "$work/src/main.swift" "$root/Margin/Geometry.swift" "$root/Margin/AI.swift" "$root/Margin/LiveRecorder.swift" \
  "$work/llama.o" "$work/whisper.o" -F "$root/Vendor/macos" -framework llama -framework whisper \
  -Xlinker -rpath -Xlinker "$root/Vendor/macos" -o "$work/engines"
say -o "$work/speech.aiff" "Today we are covering mitosis. In metaphase the chromosomes line up along the equator of the cell. Then, in anaphase, they are pulled apart."
"$work/engines" "$1" "$work/speech.aiff"
