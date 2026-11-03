# Voxlocal privacy

Voxlocal is built so that **your voice never leaves your Mac**. This page lists everything
that does leave it, and when.

## What leaves this Mac

Only two things ever use the network.

### 1. The speech model download (once per model)

- **When:** the first time Voxlocal runs, and the first time you pick a different model in
  Settings. The status line says "Downloading … (one time)".
- **Where:** `huggingface.co`, repository
  [`argmaxinc/whisperkit-coreml`](https://huggingface.co/argmaxinc/whisperkit-coreml).
- **What is sent:** ordinary HTTPS requests for the model files (file listings and
  downloads). No audio, no text, no account, no identifiers beyond what any HTTPS download
  reveals (your IP address and a user agent).
- **Stored at:** `~/Library/Application Support/Voxlocal/Models`. Once a model is there,
  Voxlocal loads it with downloads turned off, and transcription makes no network calls.
  You can delete models in Settings, or delete the folder.

### 2. Grammar cleanup with Claude (optional, on by default)

- **When:** after each dictation, only while **Clean Up Grammar with Claude** is on. While it
  is on, the menu-bar icon shows a **☁︎**, and the overlay shows a ☁︎ "sent to Claude" icon
  during the "Polishing…" step.
- **What is sent:** the **transcript text** of that one dictation, plus Voxlocal's fixed
  cleanup instructions. **Never audio.** Nothing from your screen, clipboard, or other apps.
- **How:** Voxlocal runs your installed `claude` command-line tool (Claude Code) as
  `claude -p` using your existing Claude Code login. Voxlocal never sees, stores, or asks for
  any credentials. The call is locked down:
  - `--tools ""`: no tools at all (no file access, no shell, no web)
  - `--strict-mcp-config`: none of your MCP servers
  - `--setting-sources ""`, `--disable-slash-commands`: none of your settings, hooks,
    plugins, CLAUDE.md files or skills
  - `--no-session-persistence`: Claude Code does not save the conversation to disk
  - runs in a new, empty temporary folder that is deleted right after
  - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`: asks Claude Code not to send its own
    telemetry, error reports or update checks
  - model `haiku`, with a 5-second limit
- **Where:** Anthropic, under your Claude account. Anthropic's own privacy policy and your
  account's data settings apply to that text.
- **Turn it off** in the menu or in Settings. With it off, **nothing at all leaves your
  Mac** during dictation. If cleanup fails or times out, the raw transcript is pasted; the
  text was still sent.

## What stays on this Mac

| Data | Where it lives | How long |
|---|---|---|
| Microphone audio | Memory only, recorded while you hold the hotkey | Discarded as soon as transcription finishes. **Never written to disk.** |
| Transcript text | Memory, then pasted into your app | Not saved by Voxlocal. It ends up wherever you pasted it. |
| Live preview text | Memory, shown in the overlay | Discarded when the dictation ends |
| Your clipboard | Saved in memory during a paste, then restored | About half a second |
| Settings | `UserDefaults` domain `com.jlawcordova.voxlocal`: model, hotkey, cleanup on/off, overlay toggles | Until you change them |
| Speech models | `~/Library/Application Support/Voxlocal/Models` | Until you delete them |
| Download cache | `~/Library/Caches/com.jlawcordova.voxlocal` (HTTP metadata from the model download; no audio or text) | Until macOS clears it or you delete it |

Voxlocal writes **no logs**, and has **no analytics, telemetry or crash-reporting code**.

## Permissions

- **Microphone:** used only while you hold the hotkey.
- **Accessibility:** used for three things:
  1. noticing the hotkey from any app (it ignores all other keys, except to cancel a
     dictation when you type a shortcut such as ⌥←)
  2. pressing ⌘V to paste
  3. finding *where* the text cursor is, so the overlay can sit next to it. For this it
     reads only the selection position and on-screen rectangles, **never the text** of the
     field. In password fields (or whenever macOS secure input is on) it draws nothing.

## Checking it yourself

- **Watch the network:** while Voxlocal is idle or dictating with cleanup off, this shows no
  connections:
  ```bash
  lsof -nP -i -a -p "$(pgrep -x Voxlocal)"
  ```
  With cleanup on, connections come from the separate `claude` process, not from Voxlocal.
- **Check the code:** the network-relevant code is in `Sources/Voxlocal/Transcriber.swift`
  (model download) and `Sources/VoxlocalCore/CleanupRequest.swift` and
  `ProcessRunner.swift` (cleanup call).
