// Client for tinyMuesli. Reads go through the CLI built into the app (`list`/`search --json`), which
// finds the meetings folder from the app's setting. Edits go through its MCP server (`mcp`), the
// one interface that writes, so titles, tags and speaker names are changed exactly as an agent would.
// Neither talks to the running app, so recording is never disturbed.
import { getPreferenceValues } from "@raycast/api";
import { execFile, execFileSync, spawn } from "node:child_process";
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
  app?: string;
  status: "recording" | "transcribing" | "done" | "failed" | string;
  language?: string;
  speakers: string[];
  tags: string[];
  error?: string;
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

/** The tinyMuesli executable: from the preference, else Applications, else Spotlight. */
export function binary(): string {
  const { binary: setting } = getPreferenceValues<Preferences>();
  if (setting?.trim()) {
    const path = setting.trim().replace(/^~(?=$|\/)/, homedir());
    const executable = path.endsWith(".app") || isDirectory(path) ? join(path, BINARY_IN_BUNDLE) : path;
    if (!existsSync(executable)) throw new AppNotFound(`No tinyMuesli at ${executable}`);
    return executable;
  }
  if (cachedBinary && existsSync(cachedBinary)) return cachedBinary;
  const candidates = [join("/Applications", "tinyMuesli.app"), join(homedir(), "Applications", "tinyMuesli.app")];
  try {
    const found = execFileSync("/usr/bin/mdfind", [`kMDItemCFBundleIdentifier == "${BUNDLE_ID}"`], {
      encoding: "utf8",
      timeout: 3000,
    });
    candidates.push(...found.split("\n").filter(Boolean));
  } catch {
    // Spotlight off or slow: the fixed locations are all we have.
  }
  for (const app of candidates) {
    const executable = join(app, BINARY_IN_BUNDLE);
    if (existsSync(executable)) return (cachedBinary = executable);
  }
  throw new AppNotFound("tinyMuesli.app wasn't found in Applications or by Spotlight");
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
      if (error) reject(stderr.trim() ? new Error(stderr.trim()) : error);
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

/** Calls the MCP server's `update_meeting` tool and returns the meeting as it is afterwards. */
export function updateMeeting(id: string, update: MeetingUpdate): Promise<Meeting> {
  return new Promise((resolve, reject) => {
    let executable: string;
    try {
      executable = binary();
    } catch (error) {
      return reject(error);
    }
    const server = spawn(executable, ["mcp"], { stdio: ["pipe", "pipe", "pipe"] });
    const timeout = setTimeout(() => finish(new Error("tinyMuesli's MCP server didn't answer")), 30_000);
    let buffer = "";
    let stderr = "";
    let done = false;

    const finish = (error: Error | null, meeting?: Meeting) => {
      if (done) return;
      done = true;
      clearTimeout(timeout);
      server.stdin.end();
      server.kill();
      if (error) reject(error);
      else resolve(meeting!);
    };
    const send = (message: object) => server.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");

    server.stdout.setEncoding("utf8");
    server.stdout.on("data", (chunk: string) => {
      buffer += chunk;
      let end: number;
      while ((end = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        if (!line.trim()) continue;
        let message;
        try {
          message = JSON.parse(line);
        } catch (error) {
          return finish(error as Error);
        }
        if (message.error) return finish(new Error(message.error.message));
        if (message.id === 1) {
          send({ method: "notifications/initialized" });
          send({
            id: 2,
            method: "tools/call",
            params: { name: "update_meeting", arguments: { meeting: id, ...update } },
          });
        } else if (message.id === 2) {
          const texts: string[] = (message.result?.content ?? []).map((part: { text?: string }) => part.text ?? "");
          if (message.result?.isError) return finish(new Error(texts.join("\n") || "The update failed"));
          try {
            finish(null, JSON.parse(texts[0]));
          } catch (error) {
            finish(error as Error);
          }
        }
      }
    });
    server.stderr.on("data", (chunk) => (stderr += chunk));
    server.on("error", (error) => finish(error));
    server.on("exit", (code) => finish(new Error(stderr.trim() || `tinyMuesli mcp exited with ${code}`)));

    send({
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "raycast-tinymuesli", version: "1.0" },
      },
    });
  });
}
