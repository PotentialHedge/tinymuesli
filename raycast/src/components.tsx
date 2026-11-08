import {
  Action,
  ActionPanel,
  Detail,
  Form,
  Icon,
  Keyboard,
  List,
  openExtensionPreferences,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { showFailureToast, usePromise } from "@raycast/utils";
import { useEffect, useState } from "react";
import {
  duration,
  isPlaceholder,
  knownNames,
  knownTags,
  meetingName,
  shortDate,
  startDate,
  statusLabel,
  transcriptMarkdown,
} from "./format";
import {
  AppNotFound,
  listSpeakers,
  Meeting,
  meetingLink,
  MeetingUpdate,
  readTranscript,
  updateMeeting,
} from "./tinymuesli";

/** The transcript body, re-read every few seconds while the meeting is still being recorded. */
export function useTranscript(meeting: Meeting): string {
  const read = () => {
    try {
      return readTranscript(meeting);
    } catch {
      return "";
    }
  };
  const [body, setBody] = useState(read);
  useEffect(() => {
    setBody(read());
    if (meeting.status !== "recording" && meeting.status !== "transcribing") return;
    const timer = setInterval(() => setBody(read()), 3000);
    return () => clearInterval(timer);
  }, [meeting.path, meeting.status]);
  return body;
}

export function TranscriptView({ meeting: initial, meetings, onChange: notify }: MeetingProps) {
  // Edits made from here should show here too, not only in the list behind.
  const [meeting, setMeeting] = useState(initial);
  const onChange = (updated: Meeting) => {
    setMeeting(updated);
    notify(updated);
  };
  const body = useTranscript(meeting);
  return (
    <Detail
      navigationTitle={meetingName(meeting)}
      markdown={transcriptMarkdown(meeting, body)}
      metadata={<MeetingMetadata meeting={meeting} />}
      actions={
        <MeetingActions meeting={meeting} meetings={meetings} onChange={onChange} transcript={body} inTranscript />
      }
    />
  );
}

/** Detail and list-detail metadata have the same parts under different names. */
export function MeetingMetadata({ meeting, list = false }: { meeting: Meeting; list?: boolean }) {
  const Metadata = list ? List.Item.Detail.Metadata : Detail.Metadata;
  const length = duration(meeting);
  return (
    <Metadata>
      <Metadata.Label title="Date" text={shortDate(startDate(meeting))} />
      {length && <Metadata.Label title="Duration" text={length} />}
      {meeting.app && <Metadata.Label title="App" text={meeting.app} />}
      <Metadata.Label title="Status" text={statusLabel(meeting)} />
      {meeting.language && <Metadata.Label title="Language" text={meeting.language} />}
      {meeting.speakers.length > 0 && (
        <Metadata.TagList title="Speakers">
          {meeting.speakers.map((speaker) => (
            <Metadata.TagList.Item key={speaker} text={speaker} />
          ))}
        </Metadata.TagList>
      )}
      {meeting.tags.length > 0 && (
        <Metadata.TagList title="Tags">
          {meeting.tags.map((tag) => (
            <Metadata.TagList.Item key={tag} text={tag} />
          ))}
        </Metadata.TagList>
      )}
      {meeting.error && <Metadata.Label title="Error" text={meeting.error} />}
    </Metadata>
  );
}

export interface MeetingProps {
  meeting: Meeting;
  /** All meetings, for suggesting tags and names already in use. */
  meetings: Meeting[];
  /** Called with the meeting after an edit, so the list can show it. */
  onChange: (meeting: Meeting) => void;
}

export function MeetingActions({
  meeting,
  meetings,
  onChange,
  transcript,
  inTranscript = false,
  extra,
}: MeetingProps & { transcript?: string; inTranscript?: boolean; extra?: React.ReactNode }) {
  const transcriptFile = `${meeting.path}/transcript.md`;
  const editable = meeting.status === "done" || meeting.status === "failed";
  return (
    <ActionPanel>
      {!inTranscript && (
        <Action.Push
          title="Show Transcript"
          icon={Icon.Text}
          target={<TranscriptView meeting={meeting} meetings={meetings} onChange={onChange} />}
        />
      )}
      <Action.Open title="Open in tinyMuesli" icon={Icon.AppWindowSidebarLeft} target={meetingLink(meeting.id)} />
      <Action.Open
        title="Open Transcript File"
        icon={Icon.Document}
        target={transcriptFile}
        shortcut={Keyboard.Shortcut.Common.Open}
      />
      {extra}
      {editable && (
        <ActionPanel.Section>
          <Action.Push
            title="Edit Title and Tags"
            icon={Icon.Pencil}
            shortcut={Keyboard.Shortcut.Common.Edit}
            target={<EditMeetingForm meeting={meeting} meetings={meetings} onChange={onChange} />}
          />
          {meeting.status === "done" && meeting.speakers.some((s) => s !== "Me") && (
            <Action.Push
              title="Name Speakers"
              icon={Icon.TwoPeople}
              shortcut={{ modifiers: ["cmd", "shift"], key: "n" }}
              target={<NameSpeakersForm meeting={meeting} meetings={meetings} onChange={onChange} />}
            />
          )}
        </ActionPanel.Section>
      )}
      <ActionPanel.Section>
        <Action.CopyToClipboard
          title="Copy Transcript"
          content={transcript ?? safeRead(meeting)}
          shortcut={Keyboard.Shortcut.Common.Copy}
        />
        <Action.CopyToClipboard title="Copy Meeting ID" content={meeting.id} />
        <Action.ShowInFinder path={meeting.path} shortcut={{ modifiers: ["cmd", "shift"], key: "f" }} />
      </ActionPanel.Section>
    </ActionPanel>
  );
}

function safeRead(meeting: Meeting): string {
  try {
    return readTranscript(meeting);
  } catch {
    return "";
  }
}

async function save(meeting: Meeting, update: MeetingUpdate, onChange: (m: Meeting) => void, pop: () => void) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Saving…" });
  try {
    const updated = await updateMeeting(meeting.id, update);
    onChange(updated);
    toast.style = Toast.Style.Success;
    toast.title = `Saved “${meetingName(updated)}”`;
    pop();
  } catch (error) {
    toast.hide();
    showFailureToast(error, { title: "Couldn't save the meeting" });
  }
}

function EditMeetingForm({ meeting, meetings, onChange }: MeetingProps) {
  const { pop } = useNavigation();
  const inUse = knownTags(meetings).filter((tag) => !meeting.tags.some((t) => t.toLowerCase() === tag.toLowerCase()));
  return (
    <Form
      navigationTitle={meetingName(meeting)}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save"
            icon={Icon.Check}
            onSubmit={(values: { title: string; tags: string }) =>
              save(
                meeting,
                {
                  title: values.title,
                  tags: values.tags
                    .split(",")
                    .map((t) => t.trim())
                    .filter(Boolean),
                },
                onChange,
                pop,
              )
            }
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="title"
        title="Title"
        placeholder={meeting.app ?? "Meeting"}
        defaultValue={meeting.title ?? meeting.suggestedTitle ?? ""}
        info="Leave empty to call it by its app again."
      />
      <Form.TextField
        id="tags"
        title="Tags"
        placeholder="design, weekly"
        defaultValue={meeting.tags.join(", ")}
        info="Separated by commas."
      />
      {inUse.length > 0 && <Form.Description title="In Use" text={inUse.slice(0, 30).join(", ")} />}
    </Form>
  );
}

function NameSpeakersForm({ meeting, meetings, onChange }: MeetingProps) {
  const { pop } = useNavigation();
  const speakers = meeting.speakers.filter((s) => s !== "Me");
  const names = knownNames(meetings).filter((n) => !speakers.includes(n));
  // Voices recognised from earlier meetings, as the app suggests them. Not filled in until asked:
  // a wrong name saved here would be learned as that person's voice.
  const { data: voices, isLoading } = usePromise(listSpeakers, [meeting.id], {
    onError: () => undefined,
  });
  const suggestions = new Map((voices ?? []).flatMap((v) => (v.suggestion ? [[v.name, v.suggestion] as const] : [])));
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(speakers.map((s) => [s, isPlaceholder(s) ? "" : s])),
  );
  const acceptSuggestions = () =>
    setValues((current) => {
      const next = { ...current };
      for (const [speaker, suggestion] of suggestions) if (!next[speaker]?.trim()) next[speaker] = suggestion.name;
      return next;
    });

  const submit = () => {
    const renames: Record<string, string> = {};
    for (const speaker of speakers) {
      const name = values[speaker]?.trim();
      if (name && name !== speaker) renames[speaker] = name;
    }
    if (Object.keys(renames).length === 0) return pop();
    save(meeting, { speakers: renames }, onChange, pop);
  };

  return (
    <Form
      navigationTitle={meetingName(meeting)}
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Save" icon={Icon.Check} onSubmit={submit} />
          {suggestions.size > 0 && (
            <Action
              title="Use Recognised Voices"
              icon={Icon.Wand}
              shortcut={{ modifiers: ["cmd", "shift"], key: "r" }}
              onAction={acceptSuggestions}
            />
          )}
        </ActionPanel>
      }
    >
      <Form.Description text="Giving two speakers the same name merges them. Named voices are recognised in later meetings." />
      {speakers.map((speaker) => {
        const suggestion = suggestions.get(speaker);
        const match = suggestion && `Sounds like ${suggestion.name} (${Math.round(suggestion.similarity * 100)}%)`;
        return (
          <Form.TextField
            key={speaker}
            id={speaker}
            title={speaker}
            placeholder={match ? `${suggestion.name}?` : isPlaceholder(speaker) ? "Name" : speaker}
            info={
              match &&
              `${match}, named in ${suggestion.meetings} other meeting${suggestion.meetings === 1 ? "" : "s"}. ⇧⌘R fills in every recognised voice.`
            }
            value={values[speaker] ?? ""}
            onChange={(value) => setValues((current) => ({ ...current, [speaker]: value }))}
          />
        );
      })}
      {suggestions.size > 0 && (
        <Form.Description
          title="Recognised"
          text={[...suggestions]
            .map(([speaker, s]) => `${speaker}: ${s.name} (${Math.round(s.similarity * 100)}%)`)
            .join("\n")}
        />
      )}
      {names.length > 0 && <Form.Description title="Known Names" text={names.slice(0, 30).join(", ")} />}
    </Form>
  );
}

export function AppMissing({ error }: { error: Error }) {
  return (
    <List.EmptyView
      icon={Icon.ExclamationMark}
      title={error instanceof AppNotFound ? "tinyMuesli not found" : "Couldn't read meetings"}
      description={
        error instanceof AppNotFound
          ? `${error.message}. Set its location in the extension's preferences.`
          : error.message
      }
      actions={
        <ActionPanel>
          <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
          <Action.OpenInBrowser title="Open Website" url="https://tinymuesli.com" />
        </ActionPanel>
      }
    />
  );
}
