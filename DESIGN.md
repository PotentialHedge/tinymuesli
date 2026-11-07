# tinyMuesli — Design

tinyMuesli takes notes in meetings, so you remember them. It does that one job, fully on your Mac, and stays out of the way.

## Principles

- **The filesystem is the API.** tinyMuesli writes well-structured plain files. Everything else (summaries, chat, integrations) happens outside it: in your agent, through MCP, hooks, or the CLI.
- **100% local, privacy first.** No network access except optional model downloads and update checks. Free and open source.
- **Small.** Native binary (a few MB), no bundled runtime. Models are downloaded on first use, never bundled.
- **Minimal UI.** A menu bar status icon, a list of meetings, and a read-only Meetings window that shows transcripts as chats.

## Decisions

| Area | Decision |
|---|---|
| Platform | macOS 26+ only (for now) |
| Language / shell | Swift, SwiftUI `MenuBarExtra`; one binary that also runs as the CLI and MCP server |
| System audio | Core Audio process taps (no Screen Recording permission) |
| Mic | Separate track, voice processing on (echo cancellation) |
| Transcription | Apple `SpeechAnalyzer` / `SpeechTranscriber`: on-device, OS-managed models (the OS downloads a language's model on first use via `AssetInventory`; not counted in our size). Behind a `Transcriber` protocol (a stream: append audio, get timed phrases) so Parakeet/Whisper can be added later |
| Languages | Picker in the menu: English, de, fr, es, it, pt, nl, the Nordic languages, pl and zh, filtered to `SpeechTranscriber.supportedLocales` at runtime (on macOS 26.6: en, de, fr, es, it, pt and zh variants). One entry per language (Simplified and Traditional Chinese stay separate), defaulting to the variant for the Mac's region if there is one, else the language's main one; a second Variant picker offers the others. The CLI's `--language` takes any variant. Default: the system language, else en-US. No auto-detection: the engine needs a locale |
| Speaker ID | Mic vs system channel gives Me / Others. FluidAudio's offline pipeline (pyannote segmentation + WeSpeaker embeddings + VBx, CoreML; ~34 MB of models from Hugging Face on first use) diarizes the system track into Speaker 1..n, numbered by first appearance. Words are attributed individually, so a phrase spanning a change of speaker is split |
| Voice prints | Each meeting's per-speaker embeddings go to `speakers.json`. Later: name assignment + a local DB that matches them across meetings. Not built yet |
| Track alignment | Both tracks are written against one host clock; gaps (the system tap delivers nothing while the output device is idle) are filled with silence, so t seconds into each file is the same moment |
| Meeting detection | Per-process mic usage (Core Audio). No calendar access |
| Start behaviour | Notification with one-click "Record"; per-app "always record" setting. The menu can always start a recording, and while recording, "Start New Meeting" ends it and starts the next |
| Stop behaviour | Mic released for ~5 s (shorter gaps don't interrupt the recording) → capture pauses (mic and tap released, files kept open). If another meeting starts within 5 min, the notification and the menu offer to continue the paused meeting (the gap becomes silence, so times keep counting from its start) or record a new one; "always record" apps ask instead of starting, and record anew if nobody answers. After 5 min, or when a new recording starts, the paused meeting finishes and the final pass runs. Stopping by hand finishes at once. When a meeting ends, a notification offers Continue Recording (only while it's paused; once the 5 min are up the notice is quietly replaced by one without it), Open Transcript Folder (also on click) and Delete Meeting…, which asks first (red Delete button) and moves the folder to the Trash. A meeting still being transcribed is deleted when its final pass is done, without running the hook. "Start New Meeting" doesn't post the notice If a device now runs at another sample rate (e.g. AirPods instead of the built-in mic), that track continues in a second file (`mic-2.caf`) that starts where the first ended; the final pass joins a track's files into one temporary file, so diarization sees the whole meeting |
| Muting | While you're muted, the mic track records silence (same length, so the tracks stay aligned; nothing reaches live transcription). Muted means: "Mute Me" in the menu (per recording), or, with "Don't Record Me While Muted in the Call" (**on by default**) and Accessibility access, the call app's mute button reads "Unmute" / "Turn on microphone" (checked every 2 s, also Zoom's menu bar). Apps keep the mic open while muted, so Core Audio can't tell. Ambiguous or missing buttons count as not muted. In browsers only buttons naming the mic count (another tab's video has an "Unmute" too). English labels only. `tinymuesli mute-state` shows what it reads |
| Audio retention | Optional, **off by default** (transcript only): `audio/` is deleted after a successful final pass. "Keep Audio After Transcribing" in the menu keeps it |
| Pipeline | Each track is transcribed live as it's recorded; `transcript.md` grows during the meeting (remote speech labelled "Others"). At the end, the final pass diarizes the system track and rewrites `transcript.md` + `transcript.json` with speakers. If live transcription of a track failed, the final pass transcribes its file instead |
| Crash safety | Audio is CAF (readable without finalising) and is only deleted after success. Frontmatter `status` tracks progress (`recording → recorded → transcribing → done`, or `failed` + `error`); at launch, unfinished meetings that still have audio are processed. Failed ones aren't retried automatically (`tinymuesli transcribe` re-runs) |
| Extensibility | Read-only MCP server (stdio; hand-written, no SDK), an `on-meeting-end` hook executable, CLI. No in-process plugins |
| Skipping silence | Optional, **off by default** ("Skip Silence While Recording"). Silero VAD (FluidAudio, CoreML on the CPU; ~1 MB model downloaded on first use) scores each 256 ms; stretches without speech are written as zeros, which AAC stores in ~4 kbps instead of ~32 (a quiet room is never digital silence). Errs towards keeping audio: threshold 0.5, 0.5 s kept before speech and 1.5 s after, and a failing model keeps everything. Zeros rather than cuts, so the tracks stay aligned. On a 105-minute meeting it changed fewer words than re-running transcription on the same audio; a quiet 11-minute stretch went from 5.5 MB to 0.6 MB |
| Audio threads | The capture callback only mixes down into a preallocated lock-free ring (holds 11–22 s). A queue drains it every 50 ms to encode, write and feed live transcription. If that falls too far behind, audio is dropped rather than blocking the callback, and the gap becomes silence |
| Distribution | Planned: notarized DMG; Homebrew cask |
| Updates | Sparkle 2. `scripts/release.sh` publishes a GitHub release with the zipped app and a one-item `appcast.xml`; `SUFeedURL` is the latest release's appcast. Archives are EdDSA-signed (private key in the releasing Mac's keychain, public key in Info.plist). Sparkle asks on the second launch whether to check automatically, so nothing goes online before the user agrees; "Check for Updates…" is always in the menu. A downloaded update waits to relaunch until no meeting is recording, paused, being processed or moved. The CLI and MCP server never check. Ad-hoc builds turn off library validation, because the hardened runtime otherwise refuses an embedded framework without a team ID |
| Permissions | Microphone, System Audio Recording, Notifications. Nothing else. Asked for in onboarding, not at launch. macOS has no public API for the System Audio Recording permission, so it's checked and requested through TCC's `TCCAccessPreflight`/`TCCAccessRequest`, looked up at runtime (reported as unknown if they're gone). The menu lists anything missing at the top, with a button that asks or opens the right System Settings pane, and the menu bar icon shows a badge. Notifications count as missing when banners are turned off |
| Transcript viewer | A "Meetings" window (SwiftUI `Window` scene, not opened at launch): a sidebar lists every meeting like Mail (app icon, name, Mail-style date, length and number of people, the first words said; right-click for Show in Finder or Delete), and the detail shows the selected transcript as a chat: Me on the right in the accent colour, everyone else on the left in grey (a toolbar toggle gives each speaker a colour). A message's time into the recording shows only while the pointer is on it. Clicking a meeting in the menu opens the window on it; "Show All Meetings…" opens it on the latest. Reads `transcript.json` once the meeting is done or failed, else the paragraphs of `transcript.md`, so a meeting being recorded shows its live transcript (polled every 1.5 s, followed to the bottom); the list rescans every 3 s while open, re-reading previews only for changed transcripts. Consecutive segments of one speaker form one bubble if less than 4 s apart and under ~320 characters; a time divider appears after pauses of 2 min or more. A search field at the top of the sidebar matches names, apps, speakers and the full text of every transcript (ignoring case and accents; the text is cached and only re-read when a transcript changes); results show the match count and the text around the first match, and the open meeting highlights every match, with ⌘G / ⇧⌘G and toolbar arrows to step through them. Read-only |
| Onboarding | A window on first launch: how it works, permissions, which installed meeting apps to always record, and Open at Login (turned on at first launch, since meetings are only noticed while tinyMuesli runs). Skipped for existing users (anyone with saved preferences, from tinyMuesli or Muesli before it); a reinstall that deleted the preferences but kept the meetings sees it. "Permissions → Welcome Guide…" in the menu opens it again. It always opens in the middle of the screen. While macOS shows a permission prompt, the window moves so the prompt sits inside a ring in it, with what to click above and why below; it finds the prompt by its window, waits for its open animation to settle and follows it if it moves (the `UserNotificationCenter` process, which needs no screen-recording permission). The notifications prompt is a banner, so the window sits under the top right corner and points up at it. Afterwards it goes back to the middle |

## File layout

```
~/Meetings/                      # configurable (menu: Meetings Folder…)
  2026/11/
    2026-11-04 1030 Zoom/
      transcript.md              # YAML frontmatter + speaker-labelled text
      transcript.json            # segments: start, end, speaker, track, text, confidence
      speakers.json              # voice embedding per diarized speaker (for recognising people later)
      notes.md                   # optional scratchpad (not yet)
      audio/mic.caf              # mono AAC 32 kbps at the device's rate; only kept if retention is enabled
      audio/system.caf
                                 # (+ mic-2.caf etc. if a continued meeting changed device)
```

`transcript.md`, one paragraph per turn (consecutive segments of one speaker are joined unless
there's a 30 s pause):

```markdown
---
date: 2026-11-04T10:30:00+01:00
end: 2026-11-04T11:02:10+01:00
duration: 00:32:10
app: Zoom
language: en-US
speakers: [Me, Speaker 1, Speaker 2]
status: done
---

**Me** [00:00:00] Hi everyone. Thanks for joining.

**Speaker 1** [00:00:04] Sure, the importer is feature complete.
```

`transcript.json` (`version: 1`) holds the same as segments (sentence-sized; times in seconds from
the start of the recording; `track` is `mic` or `system`), plus `start`, `end`, `app`, `language`
and `speakers`.

Any search index is a derived cache that can be rebuilt from these files.

## Agent access

- **CLI:** `list`, `show` and `search`, with `--json`.
- **MCP:** `tinymuesli mcp` offers `list_meetings`, `get_transcript` and `search_transcripts`. It only
  reads, and a meeting id only resolves to a folder that exists under the meetings root.
- **Setup:** "Copy Prompt for Agent" in the menu copies a prompt with this binary's path, which
  tells an agent how to install the MCP server and how to read what it returns.
- **Onboarding:** an "Ask about your meetings" page shows an abstract chat ("Give me a to-do list from
  my last meeting") and, for each AI app found, a button to add the MCP server: Claude Desktop
  (`claude_desktop_config.json`, restarting Claude) and the ChatGPT or Codex app (`~/.codex/config.toml`,
  where the ChatGPT desktop app's built-in Codex and the Codex CLI read local MCP servers; only our
  `[mcp_servers.tinymuesli]` table is touched). With neither installed it offers the setup prompt. The
  menu has "Add to ChatGPT…" when ChatGPT or Codex is installed.
- **Hook:** after each final pass the app runs `~/.config/tinymuesli/hooks/on-meeting-end`, if it's
  executable, with the meeting folder as its argument and working directory, plus
  `TINYMUESLI_MEETING_DIR`, `TINYMUESLI_TRANSCRIPT_MD`, `TINYMUESLI_TRANSCRIPT_JSON` and `TINYMUESLI_STATUS` (`done`
  or `failed`). Output is appended to `~/Library/Logs/tinyMuesli/on-meeting-end.log`, and a non-zero exit
  shows in the menu. It also runs after crash recovery, but not for `tinymuesli transcribe` or
  `tinymuesli record`, which you ran yourself.

Search is a substring scan of `transcript.md`, with no index, so meetings in progress are included.

## Size

The app was 444 KB before speaker ID; with FluidAudio it is 4.5 MB (built with `-Osize`, local
symbols stripped). Nearly all of that is FluidAudio's ASR/VAD code, which Swift can't dead-strip
because type metadata keeps it alive; we use only its offline diarizer. Package traits already
drop its TTS code and the 87 MB NeMo text-processing binary. Plus model downloads: ~34 MB for
diarization; the OS manages transcription models.

## Open questions

- **App size:** vendoring just FluidAudio's offline diarizer (~6.6k lines of its 96k, Apache-2.0)
  would likely get the app back to ~1 MB, at the cost of tracking upstream fixes by hand.
- **Live diarization:** remote speech is "Others" until the meeting ends. FluidAudio's streaming
  diarizers (Sortformer, LS-EEND) could label it live, but the offline pipeline is more accurate.
- **One-word turns:** a lone word that diarization attributes to a different speaker in the middle
  of someone's sentence is smoothed away. That's usually right (boundary noise), but loses a quick
  "yes" from someone else inside one transcriber phrase.
- **Language auto-detection:** `SpeechTranscriber` needs a locale. Mixed-language meetings need a
  different engine.
- Browser-based meetings (Google Meet): the browser using the mic is an ambiguous signal; v1 only shows a prompt.

## Build order

1. Menu bar app + per-process mic detection + notification prompt ✓
2. Dual-track capture (tap + mic with echo cancellation) to disk ✓
3. Live transcription → `transcript.md` ✓
4. Final pass: diarization, `transcript.json` ✓
5. CLI + MCP server + hooks ✓
6. Sparkle updates ✓
7. Signing, notarization, Homebrew cask
