# Voxlocal

Private, system-wide push-to-talk dictation for macOS (Apple Silicon, macOS 14+).

Hold a hotkey (Right Option by default), speak, release. Your speech is transcribed
**on-device** with [WhisperKit](https://github.com/argmaxinc/WhisperKit) and pasted at the
cursor of whatever app you're in. Language is detected per recording, so English, Tagalog,
Bisaya/Cebuano and mixes like Taglish all work.

Optionally, the transcript text (never audio) is cleaned up for grammar by your own Claude
Code login. See [PRIVACY.md](PRIVACY.md) for exactly what leaves your Mac and when.

## Build and run

```bash
make run      # builds build/Voxlocal.app, installs to ~/Applications, launches it
make test     # unit tests
```

Once, before the first build: `./scripts/make-signing-cert.sh` creates a local self-signed
"Voxlocal Dev" signing identity so macOS keeps your Microphone and Accessibility grants
across rebuilds.

## Using it

- **Dictate:** hold the hotkey, speak, release. The live transcript appears in a small pill
  next to your text cursor while you speak.
- **Menu bar:** the mic icon shows the state. A **☁︎** next to it means cleanup is on.
  "Last dictation" in the menu says whether the last paste was cleaned up or pasted raw, and
  why.
- **Settings… (⌘,):** speech model (Small, Medium, Large v3 Turbo, Large v3), hotkey,
  cleanup, overlay pill / caret indicator / live text, launch at login. Downloaded models
  can be deleted there.
- **Check cleanup:** `./scripts/try-cleanup.sh "your transcript"` runs the exact cleanup
  call the app makes.
- **Check the overlay:** hold ⌥ while opening the menu for **Simulate States**, or run
  `open ~/Applications/Voxlocal.app --args --simulate-states`.

## Third-party dependencies

| Package | Version | Why | What's linked |
|---|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Argmax, MIT) | 1.1.1, pinned exactly | On-device Whisper speech recognition on Core ML / the Neural Engine, plus the one-time model download | The `WhisperKit` library and its `ArgmaxCore` module, which includes Argmax's vendored copy of Hugging Face's Hub client and tokenizers (from `swift-transformers`, Apache 2.0) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apple, Apache 2.0) | 1.8.2 | Pulled in by WhisperKit's package for its own command-line tool | **Nothing.** It's resolved but not linked into Voxlocal (0 symbols in the binary) |

Everything else uses Apple frameworks: AppKit, SwiftUI, AVFoundation, Accessibility
(ApplicationServices), ServiceManagement, Observation, and Swift Testing for tests. No
analytics, telemetry or crash-reporting SDKs.

## Layout

- `Sources/VoxlocalCore`: logic without third-party code, unit-tested (dictation state
  machine, overlay geometry, cleanup call and fallbacks, transcript filtering).
- `Sources/Voxlocal`: the app (menu bar, hotkey, audio, WhisperKit, overlay, Settings).
- `scripts/`: app bundling, signing certificate, cleanup check.

## Uninstall

```bash
pkill -x Voxlocal; rm -rf ~/Applications/Voxlocal.app "$HOME/Library/Application Support/Voxlocal" ~/Library/Caches/com.jlawcordova.voxlocal
defaults delete com.jlawcordova.voxlocal
security delete-identity -c "Voxlocal Dev"   # if you created the signing certificate
```

Then remove Voxlocal from System Settings → Privacy & Security → Microphone and
Accessibility.
