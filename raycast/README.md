# tinyMuesli for Raycast

A Raycast extension for your tinyMuesli meetings. It's separate from the app and works through
the CLI inside `tinyMuesli.app` (`list`, `search`, `speakers` and `update`, with `--json`), which
makes the same edits as the app. It never talks to the running app, so it's safe to use while
recording. "Open in tinyMuesli" uses the app's `tinymuesli://meeting?id=…` link.

- **Search Meetings**: every meeting, newest first, grouped by day. Type to filter by title, app,
  tag or speaker, or pick a tag in the dropdown. The detail pane previews the transcript, and ↵ opens
  all of it, and ⌘↵ opens the meeting in tinyMuesli. A meeting being recorded updates live.
  - ⌘E edits the title and tags, and ⇧⌘N names the speakers (naming two the same merges them). Both are
    for finished meetings only, as in the app. A speaker whose voice matches one you named in another
    meeting shows the match, and ⇧⌘R fills in every match. Nothing is filled in until you ask, because a
    wrong name would be learned as that person's voice.
  - ⌘O opens `transcript.md`, ⇧⌘C copies the transcript, ⇧⌘F shows the folder in Finder, and ⌘D toggles
    the detail pane.
- **Search Transcripts**: full-text search across every transcript, ignoring case and accents, with
  hits grouped by meeting.

The meetings folder comes from the app's setting, just as for the CLI. To find the app, it asks
LaunchServices first, so it gets the copy that `open` and the link launch, a dev build in `build/`
included. After that it tries `/Applications` and `~/Applications`, then Spotlight. To use a particular
copy, set **tinyMuesli App** in the extension's preferences. The CLI commands `speakers` and `update`,
and the link, need a tinyMuesli built from this commit or later.

## Development

```sh
npm install
npm run dev     # loads the extension into Raycast and rebuilds on save
npm run lint
```

The `author` in `package.json` must be a Raycast Store handle before `ray lint` passes or the
extension can be published. For local use it doesn't matter.
