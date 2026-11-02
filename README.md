# Voxlocal

Private, system-wide push-to-talk dictation for macOS (Apple Silicon, macOS 14+).
Hold a hotkey, speak, release: your speech is transcribed **on-device** with
[WhisperKit](https://github.com/argmaxinc/WhisperKit) and pasted at the cursor.

## Build and run

```bash
make run      # builds build/Voxlocal.app, installs to ~/Applications, launches it
make test     # unit tests
```

Optional, once: `./scripts/make-signing-cert.sh` creates a local self-signed
"Voxlocal Dev" signing identity so macOS keeps your Microphone/Accessibility grants
across rebuilds.

## Status

- [x] Stage 1: hotkey → on-device transcription → paste
- [ ] Stage 2: optional grammar cleanup via `claude -p`
- [ ] Stage 3: settings window, PRIVACY.md
