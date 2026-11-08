# tinyMuesli for Raycast

A Raycast extension for your tinyMuesli meetings. It's separate from the app and only uses what the
app already exposes: the CLI inside `tinyMuesli.app` for reading (`list --json`, `search --json`) and
its MCP server (`mcp`, tool `update_meeting`) for edits. It never talks to the running app, so it's
safe to use mid-recording.

- **Search Meetings**: every meeting, newest first, grouped by day. Type to filter by title, app,
  tag or speaker, or pick a tag in the dropdown. The detail pane previews the transcript, and ↵ opens
  all of it. A meeting being recorded updates live.
  - ⌘E edits the title and tags, and ⇧⌘N names the speakers (naming two the same merges them). Both are
    for finished meetings only, as in the app.
  - ⌘O opens `transcript.md`, ⇧⌘C copies the transcript, ⇧⌘F shows the folder in Finder, and ⌘D toggles
    the detail pane.
- **Search Transcripts**: full-text search across every transcript, ignoring case and accents, with
  hits grouped by meeting.

The meetings folder comes from the app's setting, just as for the CLI. The app is found in
`/Applications`, then `~/Applications`, then by Spotlight (bundle id `com.tinymuesli.tinyMuesli`), which
also finds a dev build in `build/`. To use a particular copy, set **tinyMuesli App** in the extension's
preferences.

## Development

```sh
npm install
npm run dev     # loads the extension into Raycast and rebuilds on save
npm run lint
```

The `author` in `package.json` must be a Raycast Store handle before `ray lint` passes or the
extension can be published. For local use it doesn't matter.
