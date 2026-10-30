# Margin

A note-taking and PDF annotation app for iPad, built for lectures, textbooks and meetings. Everything, including the AI, runs on the device.

- **Ink and PDFs:** PencilKit writing on paper or PDF pages, highlighter, shapes, lasso, study tape, whiteout and redaction, comments, stamps, signatures.
- **Live Text:** handwriting turns into type where it's written, through Scribble.
- **Recording:** audio that stays in step with your notes, so tapping a stroke plays what was being said when you wrote it, with a live transcript.
- **Study:** chat with a note, summaries, flashcards with spaced review, quizzes, mind maps, and filling in what your notes missed from a recording.
- **Sync:** every note goes to a folder you choose in iCloud Drive.

## On-device AI

Nothing is sent to a server. Two open-source models download once from Hugging Face, each pinned to a checksum:

| Job | Model | Engine |
| --- | --- | --- |
| Writing | Qwen3 1.7B, Q4_K_M | [llama.cpp](https://github.com/ggml-org/llama.cpp) |
| Transcription | Whisper small.en, Q5_1 | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) |

## Building

Open `Margin.xcodeproj` in Xcode and run on an iPad with iPadOS 17 or later. The engines in `Vendor/` have no Simulator slice, so AI features are unavailable there and everything else works.

## Checks

```sh
swiftc Margin/Geometry.swift checks/main.swift -o /tmp/margin-check && /tmp/margin-check
swiftc Margin/Sync.swift checks/sync/main.swift -o /tmp/sync-check && /tmp/sync-check
checks/run-engines.sh <models folder> <work folder>
```

The last one runs the real AI code against the real models on a Mac.
