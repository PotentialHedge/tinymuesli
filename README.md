# tinyMuesli

Local, private meeting notes for macOS. [tinymuesli.com](https://tinymuesli.com) · [DESIGN.md](DESIGN.md)

Formerly called Muesli. The first launch of tinyMuesli copies Muesli's settings and
`~/.config/muesli` over. macOS asks for microphone and system audio access again, and agent MCP
configs and hook scripts need the new names (`tinymuesli`, `TINYMUESLI_*`).

Status: menu bar app, meeting detection, dual-track recording (mic = you, system audio = everyone
else), live on-device transcription, and speaker identification at the end of each meeting.
Each meeting becomes a folder with `transcript.md` and `transcript.json`; audio is deleted
afterwards unless you turn on "Keep Audio After Transcribing".

On first use, macOS downloads the speech model for your language, and tinyMuesli downloads ~34 MB of
speaker-diarization models from Hugging Face. After that nothing leaves your Mac.

## Install

tinyMuesli is an early version, so expect rough edges. It needs macOS 26 or later on an Apple Silicon Mac.

Paste this into Terminal:

```sh
curl -fsSL https://github.com/PotentialHedge/tinymuesli/releases/latest/download/install.sh | sh
```

It puts the latest version in your Applications folder and opens it. Run it again to update: it
replaces your copy where it is (asking first if tinyMuesli is running, since quitting it stops a
recording) and does nothing if you already have the latest version. A welcome window explains how
it works, asks for microphone, system audio and notification access, and lets you pick apps to record
without asking. After that tinyMuesli lives in the menu bar, not the Dock; its menu flags any
permission that's missing. Later versions install through "Check for Updates…" in the tinyMuesli menu.

Or with Homebrew:

```sh
brew install --cask potentialhedge/tap/tinymuesli
```

If you already installed tinyMuesli another way, add `--adopt` so Homebrew takes over that copy.

Or by hand:

1. Download the latest `tinyMuesli-<version>.zip` from
   [Releases](https://github.com/PotentialHedge/tinymuesli/releases/latest) and open it.
2. Drag `tinyMuesli.app` into your Applications folder.

The app isn't notarized by Apple, so with Homebrew or a download from the browser, macOS refuses to
open it the first time. Click **Done**, go to **System Settings → Privacy & Security**, scroll down to
the message about tinyMuesli, click **Open Anyway**, and confirm. (The `curl` install skips this,
because files `curl` downloads aren't quarantined.)

To uninstall, quit tinyMuesli and delete it from Applications (or `brew uninstall --cask tinymuesli`;
`--zap` also removes its settings and hooks). Your meetings stay in their folder until you delete them.

## Build & run

Requires macOS 26+ and Xcode.

```sh
scripts/build-app.sh          # → build/tinyMuesli.app (ad-hoc signed)
open build/tinyMuesli.app         # menu bar app
swift test                    # unit tests
```

The binary is also a CLI. The `curl` install and the Homebrew cask link it onto your PATH as
`tinymuesli` (for a build of your own, use `build/tinyMuesli.app/Contents/MacOS/tinyMuesli`), and
`tinymuesli help` lists the commands:

```sh
tinymuesli mic-users              # who's using the mic, and which meeting app it maps to
tinymuesli mute-state             # whether each meeting app shows you as muted
tinymuesli record --seconds 10    # test recording, then transcribe
tinymuesli transcribe "<meeting folder>" [--language de-DE] [--no-diarize] [--delete-audio]
tinymuesli languages              # transcription languages on this Mac
tinymuesli list                   # meetings, most recent first
tinymuesli show "<meeting id>"    # print a transcript
tinymuesli search "budget"        # find text in all transcripts
tinymuesli speakers "<meeting id>"  # its speakers, and who each sounds like
tinymuesli update "<meeting id>" --title "Q4 roadmap" --tags roadmap,acme --speaker "Speaker 1=Ann Lee"
```

`list`, `show`, `search`, `speakers` and `update` also take `--json`. `update` changes only what you
give it: `--title ""` removes the title, `--tags ""` removes the tags, and `--speaker` can be repeated.

`open "tinymuesli://meeting?id=<meeting id>"` (with the id URL-encoded) opens that meeting in the
Meetings window, launching tinyMuesli if it isn't running. The [Raycast extension](raycast/) uses
both.

`transcribe` re-runs the final pass on a folder that still has its `audio/` (e.g. one recorded
with audio retention on, or one whose transcription failed).

## Using it from an agent

tinyMuesli has an MCP server with the tools `list_meetings`, `get_transcript`,
`search_transcripts` and `update_meeting`. The last one lets your agent give a meeting a title and tags
and name its speakers; it never changes or deletes anything else. The easiest way to set it up is **Copy Prompt** in Settings › Assistants (Settings… in the menu): paste the
prompt into your agent, and it installs the server and learns how to use it. It contains this
copy's path, so copy it again if you move the app.

The Claude desktop app can't install servers from a chat, so click **Add…** next to Claude in Settings › Assistants
instead (ChatGPT has one too): it adds the server to Claude's config and restarts Claude. Run it again if you move the app.

To do it by hand, point your MCP client at the binary, using an absolute path:

```json
{
  "mcpServers": {
    "tinymuesli": { "command": "/Applications/tinyMuesli.app/Contents/MacOS/tinyMuesli", "args": ["mcp"] }
  }
}
```

To act when a meeting ends, put an executable at `~/.config/tinymuesli/hooks/on-meeting-end`:

```sh
#!/bin/sh
# $1 is the meeting folder, which is also the working directory.
[ "$TINYMUESLI_STATUS" = done ] || exit 0
/opt/homebrew/bin/claude -p "Summarize this meeting into notes.md: $(cat transcript.md)" > notes.md
```

It also gets `TINYMUESLI_MEETING_DIR`, `TINYMUESLI_TRANSCRIPT_MD` and
`TINYMUESLI_TRANSCRIPT_JSON`. Apps get a minimal `PATH`, so use absolute paths in the script. Output goes to
`~/Library/Logs/tinyMuesli/on-meeting-end.log`.

## Updates

The app updates itself through [Sparkle](https://sparkle-project.org): "Check for Updates…" in the
menu, and automatic checks once you allow them. To publish a version:

```sh
scripts/release.sh 0.2.0      # bumps Info.plist, builds, signs, creates GitHub release v0.2.0
git commit -am "Release 0.2.0"
```

The script signs the archive with the Sparkle key in your keychain (`generate_keys -x <file>` from
`.build/artifacts/sparkle/Sparkle/bin` exports it; keep a backup, since without it no update can be
published to existing installs). `DRY_RUN=1` builds `build/release/` without publishing. The feed is
on GitHub releases, so the repository has to be public for copies to fetch it.

Releases are code-signed with the self-signed `Muesli Self-Signed` certificate in your keychain (it keeps the old name), or
`TINYMUESLI_SIGN_IDENTITY` if set. Permissions survive an update only while the certificate stays the
same, so back it up from Keychain Access as well. Because it isn't from Apple, the first install
needs a Gatekeeper override (System Settings → Privacy & Security → Open Anyway); updates don't.

## Permissions

Run CLI commands with `open -n build/tinyMuesli.app --args <command>` if you want tinyMuesli's own
privacy permissions rather than your terminal's.

Each rebuild changes the ad-hoc signature, so macOS asks for permissions again. Set
`TINYMUESLI_SIGN_IDENTITY` to a stable (even self-signed) code-signing identity to avoid that.

## Website

`site/` is [tinymuesli.com](https://tinymuesli.com), a single static page on Cloudflare Pages:

```sh
npx wrangler pages deploy site --project-name tinymuesli
```
