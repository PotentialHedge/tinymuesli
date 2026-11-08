import { Color, Icon, Image } from "@raycast/api";
import { Meeting } from "./tinymuesli";

/** The meeting's title, else Apple Intelligence's, else its folder name without the timestamp, as the app shows it. */
export function meetingName(meeting: Meeting): string {
  if (meeting.title) return meeting.title;
  if (meeting.suggestedTitle) return meeting.suggestedTitle;
  const folder = meeting.id.split("/").pop() ?? meeting.id;
  return folder.replace(/^\d{4}-\d{2}-\d{2} \d{4} (?=.)/, "") || meeting.app || "Meeting";
}

export function startDate(meeting: Meeting): Date {
  return new Date(meeting.start);
}

/** "Today 14:01", "Yesterday 20:37", "Mon 3 Nov 10:30", "3 Nov 2025 10:30". */
export function shortDate(date: Date, now = new Date()): string {
  const time = date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(now) - day(date)) / 86_400_000);
  if (days === 0) return `Today ${time}`;
  if (days === 1) return `Yesterday ${time}`;
  if (days > 1 && days < 7) return `${date.toLocaleDateString(undefined, { weekday: "short" })} ${time}`;
  const sameYear = date.getFullYear() === now.getFullYear();
  return `${date.toLocaleDateString(undefined, { day: "numeric", month: "short", year: sameYear ? undefined : "numeric" })} ${time}`;
}

/** "1h 05m", "26m", or nil while there's no end yet. */
export function duration(meeting: Meeting): string | undefined {
  if (!meeting.end) return undefined;
  const minutes = Math.max(0, Math.round((new Date(meeting.end).getTime() - startDate(meeting).getTime()) / 60_000));
  const h = Math.floor(minutes / 60);
  return h > 0 ? `${h}h ${String(minutes % 60).padStart(2, "0")}m` : `${minutes}m`;
}

/** Grouping for the list: "Today", "Yesterday", "This Week", then month names. */
export function section(date: Date, now = new Date()): string {
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(now) - day(date)) / 86_400_000);
  if (days <= 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 7) return "This Week";
  return date.toLocaleDateString(undefined, { month: "long", year: "numeric" });
}

export function statusIcon(meeting: Meeting): Image.ImageLike {
  switch (meeting.status) {
    case "recording":
      return { source: Icon.CircleFilled, tintColor: Color.Red };
    case "transcribing":
      return { source: Icon.CircleProgress50, tintColor: Color.Orange };
    case "failed":
      return { source: Icon.ExclamationMark, tintColor: Color.Red };
    default:
      return Icon.Microphone;
  }
}

export function statusLabel(meeting: Meeting): string {
  switch (meeting.status) {
    case "recording":
      return "Recording";
    case "transcribing":
      return "Transcribing";
    case "failed":
      return "Failed";
    case "done":
      return "Done";
    default:
      return meeting.status;
  }
}

/** "Speaker 3" and "Others", the names diarization gives. */
export function isPlaceholder(name: string): boolean {
  return name === "Others" || /^Speaker \d+$/.test(name);
}

/** Values used across meetings, most frequent first, as the MCP server ranks them. */
export function ranked(values: string[]): string[] {
  const counts = new Map<string, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([value]) => value);
}

export function knownTags(meetings: Meeting[]): string[] {
  return ranked(meetings.flatMap((m) => m.tags));
}

export function knownNames(meetings: Meeting[]): string[] {
  return ranked(meetings.flatMap((m) => m.speakers.filter((s) => s !== "Me" && !isPlaceholder(s))));
}

/** Transcript paragraphs (`**Name** [00:00:04] text`) with the timestamp set off in code style. */
export function transcriptMarkdown(meeting: Meeting, body: string): string {
  const heading = `# ${meetingName(meeting)}\n\n`;
  if (!body) {
    const empty =
      meeting.status === "recording"
        ? "_Nothing transcribed yet._"
        : meeting.error
          ? `**Error:** ${meeting.error}`
          : "_Empty transcript._";
    return heading + empty;
  }
  return heading + body.replace(/^(\*\*.+?\*\*) \[(\d+:\d\d:\d\d)\] /gm, "$1 `$2` ");
}
