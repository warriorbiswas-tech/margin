# Margin

A note-taking and PDF annotation app for iPad, built for lectures, textbooks and meetings. Everything, including the AI, runs on the device.

- **Ink and PDFs:** PencilKit writing on paper or PDF pages, highlighter, shapes, dashed pen, lasso, study tape, whiteout and redaction, comments, stamps, signatures.
- **Pages:** tabs for the notes you have open, subfolders, notebook covers, whiteboards, an endless page that grows as you write, page duplication, read-only mode, stickers of your own, and cutting a photo's subject out of its background.
- **Live Text:** handwriting turns into type where it's written, through Scribble.
- **Recording:** audio that stays in step with your notes, so tapping a stroke plays what was being said when you wrote it, with a live transcript.
- **Study:** chat with a note, summaries, flashcards with spaced review, quizzes, mind maps, teach-back, explaining or solving a selected area step by step, homework from a photo, filing notes into folders, and filling in what your notes missed from a recording.
- **Sync:** every note goes to a folder you choose in iCloud Drive.

## On-device AI

Nothing is sent to a server. Open-source models download once from Hugging Face, each pinned to a checksum:

| Job | Model | Engine |
| --- | --- | --- |
| Writing | Qwen3 1.7B, Q4_K_M | [llama.cpp](https://github.com/ggml-org/llama.cpp) |
| Transcription | Whisper small.en, Q5_1 | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) |
| Other languages (optional) | Whisper small, Q5_1 | whisper.cpp |

## Building

Open `Margin.xcodeproj` in Xcode and run on an iPad with iPadOS 17 or later. The engines in `Vendor/` have no Simulator slice, so AI features are unavailable there and everything else works.

## Checks

```sh
swiftc Margin/Geometry.swift checks/main.swift -o /tmp/margin-check && /tmp/margin-check
swiftc Margin/Sync.swift checks/sync/main.swift -o /tmp/sync-check && /tmp/sync-check
checks/run-engines.sh <models folder> <work folder>
clang -fsanitize=address,undefined -F Vendor/macos Margin/LlamaEngine.c checks/bridge/fake-llama.c checks/bridge/main.c -o /tmp/bridge && /tmp/bridge
clang -c -fsanitize=thread checks/assistant/engine.c -o /tmp/engine.o && swiftc -sanitize=thread -import-objc-header checks/assistant/engine.h Margin/Geometry.swift Margin/AI.swift checks/assistant/main.swift /tmp/engine.o -o /tmp/assistant && /tmp/assistant
swiftc -O Margin/Geometry.swift Margin/Sync.swift checks/stress/main.swift -o /tmp/margin-stress && /tmp/margin-stress
```

`bridge` runs the app's llama.cpp bridge against a fake llama.cpp under the address and undefined-behaviour sanitizers, checking its buffers, prompt cache, stopping and refusals. `assistant` runs the assistant's Swift code against a stand-in engine under the thread sanitizer: streaming, stopping, leaving the screen, many questions at once, long notes and structured answers.

`run-engines.sh` runs the real AI code against the real models on a Mac. The stress test throws random input at everything that runs without a screen, then has three devices edit, trash, delete and sync at random, and fails if they don't end up with the same notes or if any edit is lost. It takes about a minute; it prints its seed, and passing that seed back replays the same random input.
