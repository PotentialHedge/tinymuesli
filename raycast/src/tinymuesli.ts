// Client for tinyMuesli, through the CLI built into the app (`list`, `search`, `speakers` and `update`,
// all with --json). The CLI finds the meetings folder from the app's setting and makes the same edits
// as the app and its MCP server. It never talks to the running app, so recording is never disturbed.
// `tinymuesli://meeting?id=…` is the one way in to the app: it opens a meeting in its window.
import { getPreferenceValues } from "@raycast/api";
import { execFile, execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface Meeting {
  /** Path relative to the meetings root, e.g. "2026/11/2026-11-04 1030 Zoom". */
  id: string;
  path: string;
  /** ISO 8601. */
  start: string;
  end?: string;
  title?: string;
  /** Apple Intelligence's title, only while the meeting has none of its own. */
  suggestedTitle?: string;
  app?: string;
  status: "recording" | "transcribing" | "done" | "failed" | string;
  language?: string;
  speakers: string[];
  tags: string[];
  error?: string;
}

export interface Speaker {
  name: string;
  /** False for the names diarization gives ("Speaker 2", "Others"). */
  named: boolean;
  /** The voice from another meeting this one sounds like; only for unnamed speakers. */
  suggestion?: { name: string; similarity: number; meetings: number };
}

export interface SearchHit {
  /** A meeting id. */
  meeting: string;
  speaker: string;
  /** "HH:MM:SS" into the recording. */
  timestamp: string;
  excerpt: string;
}

/** tinyMuesli isn't installed where we looked; the UI explains how to point at it. */
export class AppNotFound extends Error {}

const BUNDLE_ID = "com.tinymuesli.tinyMuesli";
const BINARY_IN_BUNDLE = "Contents/MacOS/tinyMuesli";

let cachedBinary: string | undefined;

/** The tinyMuesli executable: from the preference, else wherever macOS knows the app to be. */
export function binary(): string {
  const { binary: setting } = getPreferenceValues<Preferences>();
  if (setting?.trim()) {
    const path = setting.trim().replace(/^~(?=$|\/)/, homedir());
    const executable = path.endsWith(".app") || isDirectory(path) ? join(path, BINARY_IN_BUNDLE) : path;
    if (!existsSync(executable)) throw new AppNotFound(`No tinyMuesli at ${executable}`);
    return executable;
  }
  if (cachedBinary && existsSync(cachedBinary)) return cachedBinary;
  const lookups = [
    // LaunchServices: the copy `open` and tinymuesli:// links launch, so the CLI matches the app.
    // NSWorkspace through JXA asks without launching it, unlike AppleScript's `path to application`.
    () =>
      output("/usr/bin/osascript", [
        "-l",
        "JavaScript",
        "-e",
        `ObjC.import("AppKit"); const url = $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier("${BUNDLE_ID}"); url.isNil() ? "" : url.path.js`,
      ]),
    () => [join("/Applications", "tinyMuesli.app"), join(homedir(), "Applications", "tinyMuesli.app")],
    // Spotlight, which lags behind a rebuilt or moved app.
    () => output("/usr/bin/mdfind", [`kMDItemCFBundleIdentifier == "${BUNDLE_ID}"`]),
  ];
  for (const lookup of lookups) {
    for (const app of lookup()) {
      const executable = join(app, BINARY_IN_BUNDLE);
      if (existsSync(executable)) return (cachedBinary = executable);
    }
  }
  throw new AppNotFound("tinyMuesli.app wasn't found");
}

/** A command's output lines, or none if it fails or takes too long. */
function output(command: string, args: string[]): string[] {
  try {
    return execFileSync(command, args, { encoding: "utf8", timeout: 3000 }).split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function run(args: string[], signal?: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    let executable: string;
    try {
      executable = binary();
    } catch (error) {
      return reject(error);
    }
    execFile(executable, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, signal }, (error, stdout, stderr) => {
      if (error) reject(stderr.trim() ? new Error(stderr.trim().replace(/^error: /, "")) : error);
      // An app from before a command existed prints its usage instead.
      else if (stdout.startsWith("usage:"))
        reject(new Error(`This tinyMuesli is too old for “${args[0]}”. Update it.`));
      else resolve(stdout);
    });
  });
}

export async function listMeetings(signal?: AbortSignal): Promise<Meeting[]> {
  return JSON.parse(await run(["list", "--json"], signal));
}

export async function searchTranscripts(query: string, limit: number, signal?: AbortSignal): Promise<SearchHit[]> {
  return JSON.parse(await run(["search", query, "--json", "--limit", String(limit)], signal));
}

/** `transcript.md` without its frontmatter. Read from disk: it's updated live while recording. */
export function readTranscript(meeting: Meeting): string {
  const text = readFileSync(join(meeting.path, "transcript.md"), "utf8");
  const match = text.match(/^---\n[\s\S]*?\n---\n?/);
  return (match ? text.slice(match[0].length) : text).trim();
}

export interface MeetingUpdate {
  title?: string;
  tags?: string[];
  /** Current name → new name. */
  speakers?: Record<string, string>;
}

export async function listSpeakers(id: string): Promise<Speaker[]> {
  return JSON.parse(await run(["speakers", id, "--json"]));
}

/** Changes what's given and returns the meeting as it is afterwards. */
export async function updateMeeting(id: string, update: MeetingUpdate): Promise<Meeting> {
  const args = ["update", id, "--json"];
  if (update.title !== undefined) args.push("--title", update.title);
  if (update.tags !== undefined) args.push("--tags", update.tags.join(","));
  for (const [old, name] of Object.entries(update.speakers ?? {})) args.push("--speaker", `${old}=${name}`);
  return JSON.parse(await run(args));
}

/** Opens the meeting in tinyMuesli's Meetings window. */
export function meetingLink(id: string): string {
  return `tinymuesli://meeting?id=${encodeURIComponent(id)}`;
}
