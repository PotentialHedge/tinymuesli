# Writing a tinyMuesli plugin

A plugin is a GitHub repository with a `tinymuesli-plugin.json` at its root and a program, in any
language, that tinyMuesli runs. Plugins can add:

- **Transcription:** a speech-to-text provider, chosen in Settings › Recording.
- **Suggestions:** titles, tags and speaker names for each meeting, chosen in Settings › Recording.
- **An agent:** something that runs after each meeting is transcribed, turned on in Settings › Plugins.
- **Actions:** items in a meeting's right-click menu, like "Send to Notion".
- **Settings:** shown in Settings › Plugins and saved in `~/.config/tinymuesli/settings.json`.

To make it findable, add the topic **`tinymuesli-plugin`** to the repository (on GitHub: the gear next
to About). Settings › Plugins › Find Plugins and `tinymuesli plugin search` list repositories with that
topic, most stars first. People install it with `tinymuesli plugin install owner/repo` or from Settings.

The [ElevenLabs plugin](https://github.com/PotentialHedge/tinymuesli-elevenlabs) is a complete
example in about 120 lines of Python.

## The manifest

```json
{
  "id": "notion",
  "name": "Notion",
  "version": "0.1.0",
  "publisher": "Ann Lee",
  "description": "Sends meeting notes to a Notion database.",
  "network": true,
  "contributes": {
    "actions": [
      { "id": "send", "title": "Send to Notion", "command": ["python3", "notion.py"] }
    ],
    "agent": { "command": ["python3", "notion.py", "--auto"] },
    "configuration": {
      "properties": {
        "notion.token": { "type": "string", "secret": true, "description": "An internal integration token." },
        "notion.database": { "type": "string", "description": "The database's id." },
        "notion.includeTranscript": { "type": "boolean", "default": false, "description": "Add the whole transcript." }
      }
    }
  }
}
```

| Key | |
|---|---|
| `id` | Lowercase letters, digits and dashes. Also the folder name, the `--provider` name, and the prefix of every setting key. `apple`, `apple-intelligence`, `hook`, `claude-code` and `tinymuesli` are taken. |
| `name`, `version`, `description`, `publisher` | Shown in Settings and before installing. |
| `network` | `true` if it uses the internet. Shown before installing and next to its name. tinyMuesli can't enforce it, so be honest. |
| `contributes` | What it adds; at least one of the kinds below. |

A `command` is an array: the program and its arguments, never parsed by a shell. It runs in the
plugin's folder through your login shell, so `python3`, `node`, `uv` or `deno` are found as they are in
Terminal, and `./bin/tool` means a file in the repository. Before installing, tinyMuesli checks that the
program exists and warns if it doesn't. **Installing never runs anything:** no build step, no
`npm install`. Ship scripts that need nothing more than their interpreter, declare dependencies inline
(`uv run --script`, `deno run`), or commit a prebuilt binary.

## Settings

`contributes.configuration.properties` works like VS Code's:

| Key | |
|---|---|
| `type` | `string`, `boolean`, `number` or `integer` |
| `default` | Used until the user changes it |
| `description` (or `markdownDescription`) | Shown under the setting (as plain text) |
| `enum`, `enumDescriptions` | A menu of values, and their labels |
| `minimum`, `maximum` | For numbers |
| `order` | Sort order in Settings (then by key) |
| `secret` | Kept in the macOS keychain, never in `settings.json` or logs. Use it for API keys |

Keys must start with the plugin's id and a dot (`notion.token`). Every call gets the current values
in `settings`, with defaults filled in. Unset settings without a default are left out. Users can
change them in Settings › Plugins, with `tinymuesli plugin config notion token …`, or by editing
`settings.json` (a value of the wrong type falls back to the default).

## Calls

Every call starts the program, writes **one line of JSON** to its stdin, and reads its stdout:

```json
{"method": "…", "settings": {"notion.database": "abc"}, "apiVersion": 1, …}
```

Exit with status 0 on success. On failure, print a short, human message to **stderr** and exit
non-zero: tinyMuesli shows that message to the user. Everything a plugin writes to stderr is also
appended to `~/Library/Logs/tinyMuesli/plugins/<id>.log` (Show Log in Settings). The environment has
`TINYMUESLI_PLUGIN_DIR` and `TINYMUESLI_API_VERSION`.

A meeting is described as:

```json
{"id": "Clients/Acme/2026-11-04 1030 Zoom", "folder": "/Users/ann/Meetings/Clients/Acme/2026-11-04 1030 Zoom",
 "transcript": "…/transcript.md", "transcriptJSON": "…/transcript.json", "status": "done"}
```

The files are described in [DESIGN.md](../DESIGN.md#file-layout). `id` is what the CLI (`tinymuesli show ID`)
and the MCP server take. To change a meeting's title, tags or speaker names, run
`tinymuesli update ID --title …` rather than editing the files.

### Transcription

```json
"transcription": { "command": ["python3", "main.py"], "live": false, "languages": ["en-US", "de-DE"] }
```

`languages` (BCP-47 tags) fill the language picker; the default is a common set. Speakers are
identified by tinyMuesli afterwards, so a provider only returns text with timings.

Add `"multilingual": true` if it transcribes speech that mixes languages (between sentences and within
them) without being told which comes when. People who say in onboarding that their meetings are in
several languages are offered multilingual providers that cover all of them, and can find them on
GitHub from there.

**After the meeting** (`"live": false`, the default). Each track (your mic, everyone else) is sent as an
AAC file once the meeting ends:

```json
{"method": "transcribe", "file": "/var/folders/…/tinymuesli-….m4a", "language": "de-DE", "detectLanguage": false, …}
```

`detectLanguage` is `true` when the user left the language on System Default: detect it yourself if you
can, else use `language`. `languages`, when present, lists the languages the user said are spoken in
their meetings (BCP-47, e.g. `["de-CH", "en-US"]`): use them as hints for detecting. Answer with the phrases, timed in seconds from the start of the file:

```json
{"phrases": [
  {"start": 0.52, "end": 1.9, "text": "Hi everyone.",
   "words": [{"text": "Hi", "start": 0.52, "end": 0.8, "confidence": 0.98},
             {"text": " everyone.", "start": 0.8, "end": 1.9}]}
]}
```

A phrase is a sentence or so. `words` is optional but makes speaker labels better. A word's text
keeps its leading space, so the words join to the phrase's text. `confidence` (0–1) is optional.

**Live** (`"live": true`). The program starts with the recording, once per track. Its first stdin
line is the request:

```json
{"method": "transcribeLive", "sampleRate": 48000, "channels": 1, "encoding": "f32le", "language": "en-US", "detectLanguage": false, …}
```

Then raw mono 32-bit little-endian float samples follow until stdin closes, when the meeting ends.
Write each phrase as soon as it's final, **one JSON object per line** (the phrase format above) and
flush stdout. Exit once stdin has closed and every phrase is written. The transcript then grows during
the meeting. If the program falls more than 30 s behind, audio is dropped rather than blocking the
recording.

### Suggestions

```json
"suggestions": { "command": ["node", "suggest.js"] }
```

Request: `{"method": "suggest", "meeting": {…}, "transcript": "<transcript.md>", "knownTitles": […],
"knownTags": […], "myName": "Ann Lee", …}`. Use `knownTitles` and `knownTags` to suggest in the same
style and reuse tags. Answer, all optional:

```json
{"title": "Acme Kickoff", "tags": ["acme", "sales"],
 "speakers": [{"speaker": "Speaker 2", "name": "Ben", "quote": "Thanks, Ben, over to you."}]}
```

Nothing is renamed: these show as suggestions the user confirms. Calls time out after 10 minutes.

### Agent

```json
"agent": { "command": ["./run.sh"] }
```

Runs after each meeting has been transcribed, while turned on (it's on after installing). Like
tinyMuesli's `on-meeting-end` hook, it gets the meeting folder as its **last argument** and
`TINYMUESLI_MEETING_DIR`, `TINYMUESLI_TRANSCRIPT_MD`, `TINYMUESLI_TRANSCRIPT_JSON` and `TINYMUESLI_STATUS`
(`done` or `failed`), plus the request `{"method": "meetingEnded", "meeting": {…}, …}`. Its output is
ignored. A non-zero exit shows in the menu. No time limit.

### Actions

```json
"actions": [{ "id": "send", "title": "Send to Notion", "command": ["python3", "notion.py"] }]
```

Each is an item in a finished meeting's right-click menu. Request: `{"method": "action", "action": "send",
"meeting": {…}, …}`, plus the agent's environment variables. Answer with plain text, which is shown to the user,
or with:

```json
{"message": "Added to Notion.", "open": "https://notion.so/…"}
```

An `open` link (`https`, `mailto` or a file) is opened. Run one from Terminal with
`tinymuesli plugin run notion send MEETING`. Calls time out after 10 minutes.

## Developing

```sh
tinymuesli plugin install ~/code/my-plugin   # links the folder: edits apply at once
tinymuesli plugin list
tinymuesli plugin config my-plugin
tinymuesli transcribe ~/Meetings/2026-11-04\ 1030\ Zoom --provider my-plugin
tinymuesli run-agents "2026-11-04 1030 Zoom" --agent my-plugin
tinymuesli plugin run my-plugin send "2026-11-04 1030 Zoom"
```

You can also test a call by hand: `echo '{"method": "transcribe", "file": "a.m4a", "settings": {}}' | python3 main.py`.

## What plugins can and can't do

A plugin runs as the user, so it can read and write anything their account can. tinyMuesli shows what
it contributes, the exact commands and the commit before installing (and again before each update), and
installs exactly that commit. It is started as its own responsible process, so macOS doesn't let it use
tinyMuesli's microphone, system audio or Accessibility permissions: it would have to ask for its own.
It inherits no open files.

Plugins can't add windows or change tinyMuesli's interface beyond menu items and settings.
