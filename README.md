# Margin

A note-taking and PDF annotation app for iPad and Android, built for lectures, textbooks and meetings. Notes stay on the device and your own iCloud Drive or Google backup, unless you add an NVIDIA key for the online AI.

Write it. Find it. Ask it. Margin feels like writing on paper, keeps lectures, textbooks and meetings in one searchable library, and answers questions from what you wrote with an AI that can run entirely on your device.

**[margin-notes-app.vercel.app](https://margin-notes-app.vercel.app)** · [Download for Android](https://github.com/warriorbiswas-tech/margin-app/releases/latest/download/Margin-Android.apk) · [Download for iPad](https://github.com/warriorbiswas-tech/margin-app/releases/latest/download/Margin-iPad.ipa)

## Download

Public builds, the website's media and its tour video live in [warriorbiswas-tech/margin-app](https://github.com/warriorbiswas-tech/margin-app).

- **Android:** download `Margin-Android.apk`, open it and allow your browser to install apps when asked. It needs Android 10 or later on a 64-bit device.
- **iPad:** download `Margin-iPad.ipa` and install it from a Mac or Windows PC with [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io), signing in with your Apple ID. It needs iPadOS 17 or later. With a free Apple ID the app has to be reinstalled every 7 days.

Pushing a tag such as `v1.2.0` builds both apps and publishes them as a release here. Copy its APK and IPA to a new release in `margin-app` to make them public. The website in `website/` is deployed to Vercel and loads its media from `margin-app`.

## Sister app: Quirk Notes

[Quirk Notes](https://github.com/warriorbiswas-tech/Quirk-notes) is made by the same developer for the same job: free handwritten notes, PDF markup and AI study tools, with no account and no subscription. It also runs in any web browser with nothing to install. [Try Quirk Notes](https://quirk-notes.vercel.app/).

## iPad

- **Ink and PDFs:** PencilKit writing on paper or PDF pages, highlighter, shapes, dashed pen, lasso, study tape, whiteout and redaction, comments, stamps, signatures.
- **Pages:** tabs for the notes you have open, subfolders, notebook covers, whiteboards, an endless page that grows as you write, page duplication, read-only mode, stickers of your own, and cutting a photo's subject out of its background.
- **Live Text:** handwriting turns into type where it's written, through Scribble.
- **Recording:** audio that stays in step with your notes, so tapping a stroke plays what was being said when you wrote it, with a live transcript.
- **Study:** chat with a note, summaries, key points and action items, flashcards with spaced review, quizzes, mind maps, teach-back, explaining or solving a selected area step by step, homework from a photo, filing notes into folders, and filling in what your notes missed from a recording.
- **Sync:** every note goes to a folder you choose in iCloud Drive.

## Android

Written natively in Kotlin and Compose, sharing the iPad's llama.cpp bridge. It has:

- **Ink:** a stylus writes with pressure and optional Tilt for Pressure, with palm rejection, or draw with a finger. Pen, highlighter, eraser, lasso, undo and redo, zoom, hold to draw clean shapes, and scratching out to delete.
- **Pages:** tabs, subfolders, tags, covers, templates, 17 paper styles, endless pages, typed text, sticky notes, stamps, pictures, locked notes, PDF import and annotation, and exporting as a PDF or text.
- **Recording:** audio saved with the note, where tapping ink plays what was being said when it was written.
- **Study:** chat with a note, summaries, key points, flashcards with spaced review, quizzes, mind maps, explaining and solving, teach-back, and filing notes into folders. Handwriting is read on the device with Google's ML Kit, which downloads a small model once.

Not on Android yet: live transcripts, Live Text, sync between devices, the rest of the iPad's paper styles, whiteboards, stickers, study tape, whiteout and redaction, comments, signatures, graphs, document scanning, version history, read aloud, reminders, excerpts, and homework from a photo. Notes from one platform don't open on the other, because iPad ink is stored in PencilKit's own format.

## AI

The apps ship with no API key. With your own NVIDIA API key in Settings, chat, summaries and study tools use NVIDIA's hosted Nemotron model, which means your question and the notes it needs are sent to NVIDIA. The key stays in the iPad's Keychain, or encrypted by the Android Keystore. Without a key, or whenever NVIDIA can't answer, the on-device model takes over, and transcripts always stay on the device.

The on-device models are open source and download once from Hugging Face, each pinned to a checksum:

| Job | Model | Engine |
| --- | --- | --- |
| Writing | Qwen3 1.7B, Q4_K_M | [llama.cpp](https://github.com/ggml-org/llama.cpp) |
| Transcription | Whisper small.en, Q5_1 | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) |
| Other languages (optional) | Whisper small, Q5_1 | whisper.cpp |

## Building

**Android:** open `android/` in Android Studio, or run `./gradlew :app:assembleDebug` there with JDK 17 and the Android SDK. The build fetches a pinned llama.cpp release and compiles it with the NDK. Release signing comes from the `MARGIN_KEYSTORE_PATH`, `MARGIN_KEYSTORE_PASSWORD`, `MARGIN_KEY_ALIAS` and `MARGIN_KEY_PASSWORD` environment variables, which the Release workflow fills from the repository's secrets.

**iPad:** open `Margin.xcodeproj` in Xcode and run on an iPad with iPadOS 17 or later. The engines in `Vendor/` have no Simulator slice, so AI features are unavailable there and everything else works.

Without a Mac: every push to `main` builds an unsigned `Margin.ipa`. Open the latest run under Actions › Build, download `Margin-ipa` from Artifacts and unzip it, then install `Margin.ipa` with [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io) from a Windows PC or Mac, signing in with your Apple ID. With a free Apple ID the app has to be reinstalled every 7 days.

## Checks

```sh
(cd android && ./gradlew :app:testDebugUnitTest)
swiftc Margin/Geometry.swift checks/main.swift -o /tmp/margin-check && /tmp/margin-check
swiftc Margin/Sync.swift checks/sync/main.swift -o /tmp/sync-check && /tmp/sync-check
checks/run-engines.sh <models folder> <work folder>
clang -fsanitize=address,undefined -F Vendor/macos Margin/LlamaEngine.c checks/bridge/fake-llama.c checks/bridge/main.c -o /tmp/bridge && /tmp/bridge
clang -c -fsanitize=thread checks/assistant/engine.c -o /tmp/engine.o && swiftc -sanitize=thread -import-objc-header checks/assistant/engine.h Margin/Geometry.swift Margin/AI.swift checks/assistant/main.swift /tmp/engine.o -o /tmp/assistant && /tmp/assistant
swiftc -O Margin/Geometry.swift Margin/Sync.swift checks/stress/main.swift -o /tmp/margin-stress && /tmp/margin-stress
```

`bridge` runs the app's llama.cpp bridge against a fake llama.cpp under the address and undefined-behaviour sanitizers, checking its buffers, prompt cache, stopping and refusals. `assistant` runs the assistant's Swift code against a stand-in engine under the thread sanitizer: streaming, stopping, leaving the screen, many questions at once, long notes and structured answers.

`run-engines.sh` runs the real AI code against the real models on a Mac. The stress test throws random input at everything that runs without a screen, then has three devices edit, trash, delete and sync at random, and fails if they don't end up with the same notes or if any edit is lost. It takes about a minute; it prints its seed, and passing that seed back replays the same random input.
