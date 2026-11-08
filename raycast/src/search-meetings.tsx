import { Action, Icon, List } from "@raycast/api";
import { showFailureToast, usePromise } from "@raycast/utils";
import { useEffect, useMemo, useState } from "react";
import { AppMissing, MeetingActions, MeetingMetadata, useTranscript } from "./components";
import {
  duration,
  knownTags,
  meetingName,
  section,
  shortDate,
  startDate,
  statusIcon,
  statusLabel,
  transcriptMarkdown,
} from "./format";
import { listMeetings, Meeting } from "./tinymuesli";

/** The list detail is a preview; the full transcript is a push away. */
const PREVIEW_CHARACTERS = 8000;

export default function Command() {
  const { data, isLoading, error, revalidate } = usePromise(listMeetings, [], {
    onError: (error) => {
      showFailureToast(error, { title: "Couldn't list meetings" });
    },
  });
  const [edited, setEdited] = useState<Record<string, Meeting>>({});
  const [tag, setTag] = useState("");
  const [showingDetail, setShowingDetail] = useState(true);

  const meetings = useMemo(() => (data ?? []).map((m) => edited[m.id] ?? m), [data, edited]);
  const tags = useMemo(() => knownTags(meetings), [meetings]);
  const shown = tag ? meetings.filter((m) => m.tags.includes(tag)) : meetings;

  // A meeting in progress changes status when it ends; keep the list current until then.
  const live = meetings.some((m) => m.status === "recording" || m.status === "transcribing");
  useEffect(() => {
    if (!live) return;
    const timer = setInterval(revalidate, 10_000);
    return () => clearInterval(timer);
  }, [live]);

  const onChange = (meeting: Meeting) => {
    setEdited((current) => ({ ...current, [meeting.id]: meeting }));
    revalidate();
  };

  const sections = new Map<string, Meeting[]>();
  for (const meeting of shown) {
    const name = section(startDate(meeting));
    sections.set(name, [...(sections.get(name) ?? []), meeting]);
  }

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={showingDetail && shown.length > 0}
      searchBarPlaceholder="Filter by title, app, tag or speaker"
      searchBarAccessory={
        <List.Dropdown tooltip="Tag" value={tag} onChange={setTag}>
          <List.Dropdown.Item title="All Meetings" value="" />
          <List.Dropdown.Section title="Tags">
            {tags.map((t) => (
              <List.Dropdown.Item key={t} title={t} value={t} />
            ))}
          </List.Dropdown.Section>
        </List.Dropdown>
      }
    >
      {error && !data ? (
        <AppMissing error={error} />
      ) : (
        <>
          <List.EmptyView icon={Icon.Microphone} title={isLoading ? "Loading meetings…" : "No meetings yet"} />
          {[...sections].map(([name, items]) => (
            <List.Section key={name} title={name}>
              {items.map((meeting) => (
                <MeetingItem
                  key={meeting.id}
                  meeting={meeting}
                  meetings={meetings}
                  onChange={onChange}
                  showingDetail={showingDetail}
                  toggleDetail={() => setShowingDetail((shown) => !shown)}
                />
              ))}
            </List.Section>
          ))}
        </>
      )}
    </List>
  );
}

function MeetingItem({
  meeting,
  meetings,
  onChange,
  showingDetail,
  toggleDetail,
}: {
  meeting: Meeting;
  meetings: Meeting[];
  onChange: (meeting: Meeting) => void;
  showingDetail: boolean;
  toggleDetail: () => void;
}) {
  const when = shortDate(startDate(meeting));
  const length = duration(meeting);
  return (
    <List.Item
      icon={{ value: statusIcon(meeting), tooltip: statusLabel(meeting) }}
      title={meetingName(meeting)}
      subtitle={showingDetail ? undefined : meeting.title ? meeting.app : undefined}
      keywords={[meeting.app ?? "", ...meeting.tags, ...meeting.speakers].filter(Boolean)}
      accessories={
        showingDetail
          ? [{ text: when }]
          : [
              ...meeting.tags.slice(0, 3).map((t) => ({ tag: t })),
              ...(length ? [{ text: length, icon: Icon.Clock }] : []),
              { text: when, tooltip: startDate(meeting).toLocaleString() },
            ]
      }
      detail={showingDetail ? <MeetingPreview meeting={meeting} /> : undefined}
      actions={
        <MeetingActions
          meeting={meeting}
          meetings={meetings}
          onChange={onChange}
          extra={
            <Action
              title={showingDetail ? "Hide Details" : "Show Details"}
              icon={Icon.Sidebar}
              shortcut={{ modifiers: ["cmd"], key: "d" }}
              onAction={toggleDetail}
            />
          }
        />
      }
    />
  );
}

/** Raycast renders `detail` only for the selected item, so this reads one transcript at a time. */
function MeetingPreview({ meeting }: { meeting: Meeting }) {
  const body = useTranscript(meeting);
  const preview =
    body.length > PREVIEW_CHARACTERS
      ? body.slice(0, body.lastIndexOf("\n\n", PREVIEW_CHARACTERS)) + "\n\n_… ↵ shows the whole transcript._"
      : body;
  return (
    <List.Item.Detail
      markdown={transcriptMarkdown(meeting, preview)}
      metadata={<MeetingMetadata meeting={meeting} list />}
    />
  );
}
