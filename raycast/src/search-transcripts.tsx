import { Action, ActionPanel, Icon, Keyboard, List } from "@raycast/api";
import { showFailureToast, usePromise } from "@raycast/utils";
import { useMemo, useRef, useState } from "react";
import { AppMissing, TranscriptView } from "./components";
import { meetingName, shortDate, startDate } from "./format";
import { listMeetings, Meeting, SearchHit, searchTranscripts } from "./tinymuesli";

const LIMIT = 100;

export default function Command() {
  const [query, setQuery] = useState("");
  const trimmed = query.trim();
  const abortable = useRef<AbortController>(null);
  const [edited, setEdited] = useState<Record<string, Meeting>>({});

  const listing = usePromise(listMeetings, []);
  const meetings = useMemo(() => (listing.data ?? []).map((m) => edited[m.id] ?? m), [listing.data, edited]);
  const byId = useMemo(() => new Map(meetings.map((m) => [m.id, m])), [meetings]);

  const { data, isLoading, error } = usePromise(
    (q: string) => searchTranscripts(q, LIMIT, abortable.current?.signal),
    [trimmed],
    {
      abortable,
      execute: trimmed.length > 0,
      onError: (error) => {
        showFailureToast(error, { title: "Search failed" });
      },
    },
  );
  const hits = trimmed ? (data ?? []) : [];

  // Hits come newest meeting first and in order of speech within one, so grouping keeps that order.
  const groups = new Map<string, SearchHit[]>();
  for (const hit of hits) groups.set(hit.meeting, [...(groups.get(hit.meeting) ?? []), hit]);

  const onChange = (meeting: Meeting) => setEdited((current) => ({ ...current, [meeting.id]: meeting }));
  const failure = error ?? listing.error;

  return (
    <List
      isLoading={isLoading || listing.isLoading}
      searchBarPlaceholder="Search what was said"
      searchText={query}
      onSearchTextChange={setQuery}
      throttle
    >
      {failure && !listing.data ? (
        <AppMissing error={failure} />
      ) : !trimmed ? (
        <List.EmptyView
          icon={Icon.MagnifyingGlass}
          title="Search every transcript"
          description="Ignores case and accents."
        />
      ) : (
        <>
          <List.EmptyView icon={Icon.MagnifyingGlass} title={isLoading ? "Searching…" : `Nobody said “${trimmed}”`} />
          {[...groups].map(([id, items]) => {
            const meeting = byId.get(id);
            return (
              <List.Section
                key={id}
                title={meeting ? meetingName(meeting) : id}
                subtitle={meeting ? `${shortDate(startDate(meeting))} · ${items.length}` : String(items.length)}
              >
                {items.map((hit, i) => (
                  <List.Item
                    key={`${id}-${i}`}
                    icon={Icon.Bubble}
                    title={hit.excerpt}
                    accessories={[{ tag: hit.speaker }, { text: hit.timestamp }]}
                    actions={
                      <ActionPanel>
                        {meeting && (
                          <Action.Push
                            title="Show Transcript"
                            icon={Icon.Text}
                            target={<TranscriptView meeting={meeting} meetings={meetings} onChange={onChange} />}
                          />
                        )}
                        {meeting && (
                          <Action.Open
                            title="Open Transcript File"
                            icon={Icon.Document}
                            target={`${meeting.path}/transcript.md`}
                            shortcut={Keyboard.Shortcut.Common.Open}
                          />
                        )}
                        <Action.CopyToClipboard
                          title="Copy Quote"
                          content={`${hit.speaker} [${hit.timestamp}]: ${hit.excerpt}`}
                          shortcut={Keyboard.Shortcut.Common.Copy}
                        />
                        {meeting && (
                          <Action.ShowInFinder
                            path={meeting.path}
                            shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
                          />
                        )}
                      </ActionPanel>
                    }
                  />
                ))}
              </List.Section>
            );
          })}
        </>
      )}
    </List>
  );
}
