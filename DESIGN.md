# tinyMuesli — Design

tinyMuesli takes notes in meetings, so you remember them. It does that one job, fully on your Mac, and stays out of the way.

## Principles

- **The filesystem is the API.** tinyMuesli writes well-structured plain files. Everything else (summaries, chat, integrations) happens outside it: in your agent, through MCP, hooks, or the CLI.
- **100% local, privacy first.** No network access except optional model downloads and update checks. Free and open source.
- **Small.** Native binary (a few MB), no bundled runtime. Models are downloaded on first use, never bundled.
- **Minimal UI.** A menu bar status icon, a list of meetings, and a Meetings window that shows transcripts as chats, where you can give a meeting a title and tags and name its speakers.

## Decisions

| Area | Decision |
|---|---|
| Platform | macOS 26+ only (for now) |
| Language / shell | Swift, SwiftUI `MenuBarExtra`; one binary that also runs as the CLI and MCP server |
| System audio | Core Audio process taps (no Screen Recording permission) |
| Mic | Separate track, voice processing on (echo cancellation) |
| Transcription | Apple `SpeechAnalyzer` / `SpeechTranscriber`: on-device, OS-managed models (the OS downloads a language's model on first use via `AssetInventory`; not counted in our size). Behind a `Transcriber` protocol (a stream: append audio, get timed phrases) so Parakeet/Whisper can be added later |
| Languages | Picker in the menu and in Settings: English, de, fr, es, it, pt, nl, the Nordic languages, pl and zh, filtered to `SpeechTranscriber.supportedLocales` at runtime (on macOS 26.6: en, de, fr, es, it, pt and zh variants). One entry per language (Simplified and Traditional Chinese stay separate), defaulting to the variant for the Mac's region if there is one, else the language's main one; a second Variant picker offers the others. The CLI's `--language` takes any variant. Default: the system language, else en-US |
| Language changes | The engine needs a locale and can't identify languages, so each track is watched while recording (`LanguageMonitor`): a check runs when the last 30 s of words score below 0.6 confidence, or when NaturalLanguage reads them as another language (some models write a language they don't know out in that language with barely lower confidence: Swiss German scores English speech 0.6–0.8, the English model scores German 0.2–0.4). The check (`LanguageDetector`) transcribes that audio in the current language and up to three candidates (the text's language, then your macOS languages) and suggests one that scores 0.15 higher, or 0.04 higher if the text agrees. You're asked by notification (and in the menu); a switch re-transcribes that track from where the new language started, from the last 5 min of audio kept at 16 kHz (`LanguageSwitchingStream`), and is saved as `language-switches` so a re-run from the audio does the same. The menu's Meeting Language switches both tracks from now |
| Speaker ID | Mic vs system channel gives Me / Others. FluidAudio's offline pipeline (pyannote segmentation + WeSpeaker embeddings + VBx, CoreML; ~34 MB of models from Hugging Face on first use) diarizes the system track into Speaker 1..n, numbered by first appearance. Words are attributed individually, so a phrase spanning a change of speaker is split |
| Voice prints | Each meeting's per-speaker embeddings (WeSpeaker, 256 values) go to `speakers.json`. Naming a speaker renames it there too, which makes it a known voice: an unnamed speaker in another meeting whose embedding has a cosine similarity of 0.6 or more to a named one is suggested as that person ("Maybe Ann · Confirm" in the chat, and in the MCP transcript note). On the first meetings, the same person scored 0.65–0.96 across meetings and different people at most 0.49. Each name is suggested for one speaker per meeting at most, closest pairs first. No separate database: the known voices are read from the meetings' files, so they can't drift from them |
| Suggestions | With Apple Intelligence (FoundationModels' on-device model; "Suggest Titles and Names" in Settings › Recording, on by default) each meeting gets `suggestions.json` after its final pass, and finished meetings without one get it at launch (or when Settings sees the model become ready), one at a time in the background. While Apple Intelligence isn't ready, Settings › Recording says why (turned off, Siri's language differs, still downloading), checks again every second, and offers Open Settings… and the agent prompt: a title, up to 3 tags and speaker names. Nothing is changed until the user picks one: the list shows the suggested title greyed with ✨ while a meeting has none (the menu with ✨, Raycast with a ✨ icon, and `list --json` / MCP as `suggestedTitle`), the details offer it with Use, the tags as ✨ chips, and names as "Maybe Ann" like a voice match (which wins for the same speaker). The model sees ~4,000 tokens, so a longer meeting is summarised in parts (at most 10, sampled) and titled from the summaries, with the user's other titles as examples of the style; filler tags ("meeting", "updates") are dropped and tags matching one in use take its spelling. On these meetings titles were reasonable (1–20 s, 2 min for 2 hours). Names: asking the model who a name refers to assigned nearly every name to someone, so instead NaturalLanguage finds personal names, a name only counts where it stands as you'd say it to someone (between punctuation, at the start or end of a turn, after hi/thanks), the model only says whether it's said *to* someone, and the next (or, for "thanks, Ann", the previous) speaker gets it. The user's own name and its short forms are skipped. Still a weak signal, so the quote is shown with it. Judging the transcription language with it didn't work (it called correct English wrong, and refused transcripts with swearing) |
| Track alignment | Both tracks are written against one host clock; gaps (the system tap delivers nothing while the output device is idle) are filled with silence, so t seconds into each file is the same moment |
| Meeting detection | Per-process mic usage (Core Audio). No calendar access |
| Start behaviour | Notification with one-click "Record"; per-app "always record" setting. The menu can always start a recording, and while recording, "Start New Meeting" ends it and starts the next |
| Stop behaviour | Mic released for ~5 s (shorter gaps don't interrupt the recording) → capture pauses (mic and tap released, files kept open). If another meeting starts within 5 min, the notification and the menu offer to continue the paused meeting (the gap becomes silence, so times keep counting from its start) or record a new one; "always record" apps ask instead of starting, and record anew if nobody answers. After 5 min, or when a new recording starts, the paused meeting finishes and the final pass runs. Stopping by hand finishes at once. When a meeting ends, a notification offers Continue Recording (only while it's paused; once the 5 min are up the notice is quietly replaced by one without it), Open Transcript Folder (also on click) and Delete Meeting…, which asks first (red Delete button) and moves the folder to the Trash. A meeting still being transcribed is deleted when its final pass is done, without running the hook. "Start New Meeting" doesn't post the notice If a device now runs at another sample rate (e.g. AirPods instead of the built-in mic), that track continues in a second file (`mic-2.caf`) that starts where the first ended; the final pass joins a track's files into one temporary file, so diarization sees the whole meeting |
| Muting | While you're muted, the mic track records silence (same length, so the tracks stay aligned; nothing reaches live transcription). Muted means: "Mute Me" in the menu (per recording), or, with "Don't Record Me While Muted in the Call" (**on by default**) and Accessibility access, the call app's mute button reads "Unmute" / "Turn on microphone" (checked every 2 s, also Zoom's menu bar). Apps keep the mic open while muted, so Core Audio can't tell. Ambiguous or missing buttons count as not muted. In browsers only buttons naming the mic count (another tab's video has an "Unmute" too). English labels only. `tinymuesli mute-state` shows what it reads. Accessibility is one of the onboarding permissions (and flagged in the menu) while that setting is on; macOS doesn't say whether it has asked, so once its alert has been shown a missing permission counts as denied (Open Settings…). From then on onboarding can be continued without it (a plain "Skip for Now" in place of Continue) and doesn't reopen for it at launch; the menu still flags it |
| Audio retention | Optional, **off by default** (transcript only): `audio/` is deleted after a successful final pass. "Keep Audio After Transcribing" in Settings keeps it |
| Pipeline | Each track is transcribed live as it's recorded; `transcript.md` grows during the meeting (remote speech labelled "Others"). At the end, the final pass diarizes the system track and rewrites `transcript.md` + `transcript.json` with speakers. If live transcription of a track failed, the final pass transcribes its file instead |
| Crash safety | Audio is CAF (readable without finalising) and is only deleted after success. Frontmatter `status` tracks progress (`recording → recorded → transcribing → done`, or `failed` + `error`); at launch, unfinished meetings that still have audio are processed. Failed ones aren't retried automatically (`tinymuesli transcribe` re-runs) |
| Extensibility | MCP server (stdio; hand-written, no SDK) that reads, and only writes a meeting's title, tags and speaker names, an `on-meeting-end` hook executable, CLI. No in-process plugins |
| Skipping silence | Optional, **off by default** ("Skip Silence While Recording"). Silero VAD (FluidAudio, CoreML on the CPU; ~1 MB model downloaded on first use) scores each 256 ms; stretches without speech are written as zeros, which AAC stores in ~4 kbps instead of ~32 (a quiet room is never digital silence). Errs towards keeping audio: threshold 0.5, 0.5 s kept before speech and 1.5 s after, and a failing model keeps everything. Zeros rather than cuts, so the tracks stay aligned. On a 105-minute meeting it changed fewer words than re-running transcription on the same audio; a quiet 11-minute stretch went from 5.5 MB to 0.6 MB |
| Audio threads | The capture callback only mixes down into a preallocated lock-free ring (holds 11–22 s). A queue drains it every 50 ms to encode, write and feed live transcription. If that falls too far behind, audio is dropped rather than blocking the callback, and the gap becomes silence |
| Distribution | Planned: notarized DMG; Homebrew cask |
| Updates | Sparkle 2. `scripts/release.sh` publishes a GitHub release with the zipped app and a one-item `appcast.xml`; `SUFeedURL` is the latest release's appcast. Archives are EdDSA-signed (private key in the releasing Mac's keychain, public key in Info.plist). Sparkle asks on the second launch whether to check automatically, so nothing goes online before the user agrees; "Check for Updates…" is always in the menu. A downloaded update waits to relaunch until no meeting is recording, paused, being processed or moved. The CLI and MCP server never check. Ad-hoc builds turn off library validation, because the hardened runtime otherwise refuses an embedded framework without a team ID |
| Permissions | Microphone, System Audio Recording, Notifications. Nothing else. Asked for in onboarding, not at launch. macOS has no public API for the System Audio Recording permission, so it's checked and requested through TCC's `TCCAccessPreflight`/`TCCAccessRequest`, looked up at runtime (reported as unknown if they're gone). The menu lists anything missing at the top, with a button that asks or opens the right System Settings pane, and the menu bar icon shows a badge. Notifications count as missing when banners are turned off |
| Dock and ⌘Tab | A menu bar app (`LSUIElement`) until one of its windows opens (Meetings, the welcome guide, an update prompt): then it switches to a regular app with a Dock icon, a place in ⌘Tab and its own menu bar. Closing the last window switches it back; the menu bar item keeps running. Panels (open dialogs, alerts) don't count |
| Transcript viewer | A "Meetings" window (SwiftUI `Window` scene, not opened at launch): a sidebar lists every meeting like Mail (app icon, name, Mail-style date, length and number of people, the first words said; right-click for Rename… (its title, as in its details; once it's done or failed), Show in Finder or Delete), or, with the sidebar's By Date / By Folder control (two segments, like tabs; remembered; each layout gets a fresh list, since animating the shared rows between them left stale ones drawn over each other), in their folders below the meetings folder as a tree: each folder a disclosure group with its subfolders, then its meetings, both newest first (folders by their newest meeting); folders remember being closed, open while searching so every result shows, and open when a meeting in them is picked (e.g. in the menu), and include empty ones (not while searching). In that mode the sidebar edits the folders like Finder: drag a meeting or folder onto a folder to move it there (onto a meeting, into that meeting's folder; onto empty space, into the meetings folder itself), with the folder under the pointer highlighted; a name already taken gets " (2)", and a folder dropped on itself just goes back. New Folder (a toolbar button beside the By Date / By Folder control, or right-click a folder, a meeting or empty space in the sidebar) asks for a name, as does Rename…; Delete Folder… moves it to the Trash with everything in it, saying how many meetings go. Emptied folders stay, unlike moving the meetings folder. A meeting still being recorded, waiting to be continued or in its final pass can't be moved, nor a folder with one in it renamed, moved or deleted (an alert says why), since the recorder writes to its path. The selected meeting and closed folders follow a move or rename; right-click a folder for Show in Finder, and the detail shows the selected transcript as a chat: Me on the right in the accent colour, everyone else on the left in grey (a toolbar toggle gives each speaker a colour). A message's time into the recording shows only while the pointer is on it. (one hover region for the whole chat, which finds the bubble from their frames: a region per bubble made SwiftUI re-check every one on each frame of a sidebar or inspector animation, so nearly every frame was late) Clicking a meeting in the menu opens the window on it; "Show All Meetings…" opens it on the latest. Reads `transcript.json` once the meeting is done or failed, else the paragraphs of `transcript.md`, so a meeting being recorded shows its live transcript (polled every 1.5 s, followed to the bottom); the list rescans every 3 s while open, re-reading previews only for changed transcripts. Consecutive segments of one speaker form one bubble if less than 4 s apart and under ~320 characters; a time divider appears after pauses of 2 min or more. A search field at the top of the sidebar matches names, apps, speakers and the full text of every transcript (ignoring case and accents; the text is cached and only re-read when a transcript changes); results show the match count and the text around the first match, and the open meeting highlights every match, with ⌘G / ⇧⌘G and toolbar arrows to step through them. Each meeting has a details inspector (⌘I), attached to the split view rather than the chat so the three columns share the window (inside the chat's column, opening it squeezed the sidebar; the window's minimum size goes on the split view before `.inspector`, since a frame around the inspector made it snap open instead of sliding): its title, tags (with the ones in use offered), speakers (renaming writes the name into `transcript.md`, `transcript.json` and `speakers.json`; typing offers names used in other meetings, the voice match first; the same name twice merges two speakers), the colour toggle and info. With Reduce Motion on (System Settings › Accessibility › Display), the inspector, scrolling to matches and the onboarding pages switch without sliding, and the live waveform and the prompt guide's ring don't pulse. Editing waits until the meeting is done (failed is fine for title and tags), because the recorder and the final pass rewrite the files from their own copy. Re-running the final pass keeps title and tags but goes back to "Speaker n" |
| Chat about a meeting | The Meetings window's toolbar has a button per assistant whose config has tinyMuesli's MCP server (Claude, ChatGPT; re-checked when the app comes to the front, none if neither does or its app is missing), showing that app's own icon (else a speech-bubble symbol). It opens a chat with one line naming the meeting as you would (title, else app, and its date and time; no id or tool names, since it lands in the message box for you to read) and saying tinyMuesli can read it; the assistant finds it with `list_meetings`. No transcript goes into the URL. Only the desktop apps, never the web (claude.ai and chatgpt.com can't reach the local MCP server): a button shows only when the app that opens its link is installed. Claude opens `claude://claude.ai/new?q=` (it warns about any prompt arriving by link); ChatGPT opens `codex://threads/new?prompt=…&mode=work`, the undocumented link the ChatGPT app builds itself, in Work mode where it has local MCP tools, with the prompt in the box unsent. Coming back to tinyMuesli 3–90 s after a click (or never leaving, if the link opened nothing) shows an alert, "Didn't open in ChatGPT?", with a short prompt to paste ("Let's talk about my Zoom meeting from … tinyMuesli recorded and transcribed it on this Mac.") and Copy Prompt |
| Settings | SwiftUI `Settings` scene (⌘, or "Settings…" in the menu), tabbed: General (open at login, meetings folder, updates), Recording (language, muting, silence, keeping audio, which installed meeting apps to always record), Assistants (add the MCP server to Claude or ChatGPT, with whether it's there; copy the agent prompt), Permissions (each one's state with Allow or Open System Settings, and the welcome guide). The menu keeps the language picker and anything urgent (missing permissions, recording controls) |
| Onboarding | A window on first launch: how it works, permissions, which installed meeting apps to always record, Apple Intelligence (only on Macs that support it: whether its on-device model is ready, downloading or turned off; Siri's language is read from its preferences, since Apple Intelligence never turns on while it differs from the Mac's, and a copyable prompt lets the user's agent diagnose the rest), and Open at Login (turned on at first launch, since meetings are only noticed while tinyMuesli runs). Skipped for existing users (anyone with saved preferences, from tinyMuesli or Muesli before it); a reinstall that deleted the preferences but kept the meetings sees it. "Permissions → Welcome Guide…" in the menu opens it again. It always opens in the middle of the screen. While macOS shows a permission prompt, the window moves so the prompt sits inside a ring in it, with what to click above and why below; it finds the prompt by its window, waits for its open animation to settle and follows it if it moves (the `UserNotificationCenter` process, which needs no screen-recording permission). The notifications prompt is a banner, so the window sits under the top right corner and points up at it. Afterwards it goes back to the middle |

## File layout

```
~/Meetings/                      # configurable (menu: Meetings Folder…)
  2026/11/
    2026-11-04 1030 Zoom/
      transcript.md              # YAML frontmatter + speaker-labelled text
      transcript.json            # segments: start, end, speaker, track, text, confidence
      speakers.json              # voice embedding per diarized speaker (for recognising people later)
      suggestions.json           # title, tags and speaker names suggested by Apple Intelligence
      notes.md                   # optional scratchpad (not yet)
      audio/mic.caf              # mono AAC 32 kbps at the device's rate; only kept if retention is enabled
      audio/system.caf
                                 # (+ mic-2.caf etc. if a continued meeting changed device)
```

New meetings go in `year/month/`, but that's only where they start: rename meeting folders, move
them, and group them into folders of your own at any depth (`Clients/Acme/Kickoff/`). A meeting is
any folder with a `transcript.md` or an `audio/` folder (one being recorded before anyone spoke);
folders inside a meeting, hidden folders, packages and symlinks aren't searched, and the walk stops
8 levels down. Meetings are ordered by the `date:` in their frontmatter, not by folder. A meeting's
id (CLI, MCP, `tinymuesli://` links) is its path below the meetings folder, so it changes when the
folder is renamed or moved. Moving to another meetings folder keeps each meeting's path below it.

`transcript.md`, one paragraph per turn (consecutive segments of one speaker are joined unless
there's a 30 s pause):

```markdown
---
date: 2026-11-04T10:30:00+01:00
end: 2026-11-04T11:02:10+01:00
duration: 00:32:10
app: Zoom
language: en-US
language-switches: [system 312.5 de-CH]   # optional: track, seconds, language
speakers: [Me, Speaker 1, Speaker 2]
tags: [roadmap]                  # optional, as is title: (above date:)
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
- **MCP:** `tinymuesli mcp` offers `list_meetings`, `get_transcript`, `search_transcripts` and `update_meeting`
  (title, tags, speaker names: the only thing it writes, and only for finished meetings). A meeting id only
  resolves to a folder that exists under the meetings root. To get meetings named and tagged as they're read,
  the server's `instructions`, the tool descriptions and the setup prompt ask agents to fill them in, and a finished
  meeting's markdown transcript ends with a note listing what's missing, voices recognised from earlier meetings,
  and the names and tags already in use.
- **Setup:** "Copy Prompt" in Settings › Assistants copies a prompt with this binary's path, which
  tells an agent how to install the MCP server and how to read what it returns.
- **Onboarding:** an "Ask about your meetings" page shows an abstract chat ("Give me a to-do list from
  my last meeting") and, for each AI app found, a button to add the MCP server: Claude Desktop
  (`claude_desktop_config.json`, restarting Claude) and the ChatGPT or Codex app (`~/.codex/config.toml`,
  where the ChatGPT desktop app's built-in Codex and the Codex CLI read local MCP servers; only our
  `[mcp_servers.tinymuesli]` table is touched). With neither installed it offers the setup prompt. Settings ›
  Assistants has the same buttons, and shows which apps already have the server.
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
- **Language changes are asked about, not automatic,** and are per track, not per sentence: a
  speaker who mixes languages within a sentence is transcribed in the track's current language.
- Browser-based meetings (Google Meet): the browser using the mic is an ambiguous signal; v1 only shows a prompt.

## Build order

1. Menu bar app + per-process mic detection + notification prompt ✓
2. Dual-track capture (tap + mic with echo cancellation) to disk ✓
3. Live transcription → `transcript.md` ✓
4. Final pass: diarization, `transcript.json` ✓
5. CLI + MCP server + hooks ✓
6. Sparkle updates ✓
7. Signing, notarization, Homebrew cask
