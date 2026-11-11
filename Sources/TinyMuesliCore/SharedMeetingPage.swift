import Foundation

/// The web page `SharedMeeting` is sent as: one self-contained HTML file (no scripts or fonts
/// from elsewhere) that reads like the Meetings window's chat, works on any device, and ends
/// with what tinyMuesli is, for whoever receives it.
extension SharedMeeting {
    public static let website = "https://tinymuesli.com"

    public func html() throws -> String {
        let importLink = try importURL().absoluteString
        let messages = ChatTranscript.messages(from: transcript.segments)
        let others = speakers.filter { $0 != sharedBy }
        let iso = ISO8601DateFormatter()

        var chat = ""
        var previous: ChatTranscript.Message?
        for message in messages {
            let gap = previous.map { message.start - $0.end >= 120 } ?? true
            if gap {
                let at = transcript.start.addingTimeInterval(message.start)
                chat += "<p class=\"divider\"><time datetime=\"\(iso.string(from: at))\" data-format=\"time\">\(Self.escape(at.formatted(date: .omitted, time: .shortened)))</time></p>\n"
            }
            let mine = message.speaker == sharedBy
            let startsGroup = gap || previous?.speaker != message.speaker
            let colour = mine ? 0 : (others.firstIndex(of: message.speaker) ?? 0) % Self.palette + 1
            chat += "<div class=\"msg\(mine ? " me" : "")\(startsGroup ? " first" : "")\" style=\"--c: var(--s\(colour))\">"
            if startsGroup { chat += "<div class=\"who\">\(Self.escape(message.speaker))</div>" }
            chat += "<div class=\"row\"><p class=\"bubble\">\(Self.escape(message.text))</p>"
            chat += "<span class=\"at\">\(TranscriptRenderer.timestamp(message.start))</span></div></div>\n"
            previous = message
        }
        if messages.isEmpty { chat = "<p class=\"divider\">Nobody said anything in this meeting.</p>\n" }

        var facts = ["<time datetime=\"\(iso.string(from: transcript.start))\" data-format=\"date\">\(Self.escape(transcript.start.formatted(date: .complete, time: .shortened)))</time>"]
        if let end = transcript.end { facts.append(Self.length(end.timeIntervalSince(transcript.start))) }
        if let app = transcript.app { facts.append(Self.escape(app)) }

        let people = speakers.map { speaker -> String in
            let colour = speaker == sharedBy ? 0 : (others.firstIndex(of: speaker) ?? 0) % Self.palette + 1
            return "<li style=\"--c: var(--s\(colour))\">\(Self.escape(speaker))</li>"
        }.joined()
        let tagList = tags.isEmpty ? "" : "<ul class=\"tags\">" + tags.map { "<li>#\(Self.escape($0))</li>" }.joined() + "</ul>"
        let language = transcript.language.map { Self.escape(String($0.split(separator: "-").first ?? "en")) } ?? "en"

        return """
        <!doctype html>
        <html lang="\(language)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="tinyMuesli">
        <title>\(Self.escape(name))</title>
        <style>\(Self.style)</style>
        </head>
        <body>
        <header>
          <a class="brand" href="\(Self.website)">tiny<span>Muesli</span></a>
          <h1>\(Self.escape(name))</h1>
          <p class="facts">\(facts.joined(separator: " · "))</p>
          <ul class="people">\(people)</ul>
          \(tagList)
          <p class="shared">Shared by \(Self.escape(sharedBy))</p>
          <div class="add">
            <a class="button" id="add" href="\(importLink)">Add to tinyMuesli</a>
            <p class="mac">Have tinyMuesli on your Mac? Add this meeting to it, to search it and ask your AI assistant about it.</p>
            <p class="missing">Nothing happened? You may not have tinyMuesli yet. <a href="\(Self.website)">Get it free</a>, then open this page again.</p>
          </div>
        </header>
        <main>
        \(chat)</main>
        <footer>
          <h2>Take notes like this in your own meetings</h2>
          <p>tinyMuesli notices when a call starts, transcribes it and works out who said what, entirely on your Mac. Audio never leaves it, and every meeting is plain files you own. Free and open source.</p>
          <a class="button" href="\(Self.website)">Get tinyMuesli for Mac</a>
        </footer>
        <script>\(Self.script)</script>
        </body>
        </html>

        """
    }

    /// "32 min", "1 h 5 min".
    public static func length(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min")
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(c)
            }
        }
        return result
    }

    /// Speaker colours besides the sharer's (`--s0`, the accent).
    static let palette = 6

    static let style = """
    :root {
      --bg: #fbf8f3; --fg: #24201b; --muted: #6d655b; --line: #e6dfd4; --card: #fff;
      --accent: #b5562b; --accent-fg: #fff; --bubble: #efe9df;
      --s0: var(--accent); --s1: #2f6fb0; --s2: #2e8a57; --s3: #8a4fb5; --s4: #b0832a; --s5: #b03a5b; --s6: #2a8c8c;
      color-scheme: light;
    }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #171512; --fg: #ece6dc; --muted: #a39a8e; --line: #2e2a24; --card: #1f1c18;
              --accent: #e0814f; --accent-fg: #171512; --bubble: #2a2621;
              --s1: #6ea8e6; --s2: #63c08b; --s3: #b98ae0; --s4: #dcb25a; --s5: #e57a97; --s6: #5cc4c4;
              color-scheme: dark; }
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--fg);
           font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", "Segoe UI", Roboto, sans-serif; }
    header, main, footer { max-width: 46rem; margin: 0 auto; padding: 0 16px; }
    header { padding-top: 2rem; padding-bottom: 1.5rem; border-bottom: 1px solid var(--line); }
    .brand { font-weight: 700; letter-spacing: -0.02em; color: var(--fg); text-decoration: none; }
    .brand span { color: var(--accent); }
    h1 { font-size: clamp(1.6rem, 6vw, 2.3rem); line-height: 1.1; letter-spacing: -0.02em; margin: 1.25rem 0 .4rem; overflow-wrap: anywhere; }
    .facts, .shared { color: var(--muted); margin: 0 0 .75rem; }
    ul.people, ul.tags { list-style: none; padding: 0; margin: 0 0 .75rem; display: flex; flex-wrap: wrap; gap: .4rem; }
    .people li { border: 1px solid var(--line); border-radius: 999px; padding: .1rem .7rem; font-size: .9rem; }
    .people li::before { content: ""; display: inline-block; width: .55rem; height: .55rem; border-radius: 50%;
                         background: var(--c); margin-right: .4rem; }
    .tags li { color: var(--muted); font-size: .9rem; }
    .add { background: var(--card); border: 1px solid var(--line); border-radius: .8rem; padding: 1rem 1.1rem; margin-top: 1rem; }
    .add p { margin: .6rem 0 0; color: var(--muted); font-size: .9rem; }
    .add .missing { display: none; }
    .maybe-missing .add .missing { display: block; }
    .not-mac .add { display: none; }
    .button { display: inline-block; padding: .6rem 1.1rem; border-radius: .6rem; font-weight: 600;
              text-decoration: none; background: var(--accent); color: var(--accent-fg); }
    a { color: var(--accent); }
    main { padding-top: 1rem; padding-bottom: 2rem; }
    .divider { text-align: center; color: var(--muted); font-size: .8rem; margin: 1.4rem 0 .4rem; }
    .msg { display: flex; flex-direction: column; align-items: flex-start; margin-top: 3px; }
    .msg.first { margin-top: 12px; }
    .msg.me { align-items: flex-end; }
    .who { font-size: .8rem; font-weight: 600; color: var(--c); margin: 0 .8rem 2px; }
    .row { display: flex; align-items: center; gap: .5rem; max-width: min(36rem, 85%); }
    .me .row { flex-direction: row-reverse; }
    .bubble { margin: 0; padding: .45rem .8rem; border-radius: 1.1rem; background: var(--bubble); overflow-wrap: anywhere; }
    .me .bubble { background: var(--accent); color: var(--accent-fg); }
    .at { font-size: .75rem; color: var(--muted); opacity: 0; white-space: nowrap; font-variant-numeric: tabular-nums; }
    .msg:hover .at { opacity: 1; }
    footer { border-top: 1px solid var(--line); padding-top: 1.5rem; padding-bottom: 3rem; }
    footer h2 { font-size: 1.15rem; margin: 0 0 .4rem; }
    footer p { color: var(--muted); margin: 0 0 1rem; }
    @media print { .add, footer .button, .at { display: none; } }
    """

    /// Dates in the reader's own time zone and format; hides the button where it can't work, and
    /// says what's missing if clicking it seems to do nothing.
    static let script = """
    (function () {
      var full = new Intl.DateTimeFormat(undefined, { dateStyle: "full", timeStyle: "short" });
      var time = new Intl.DateTimeFormat(undefined, { timeStyle: "short" });
      document.querySelectorAll("time[data-format]").forEach(function (t) {
        var d = new Date(t.getAttribute("datetime"));
        if (!isNaN(d)) t.textContent = (t.dataset.format === "date" ? full : time).format(d);
      });
      var mac = /Macintosh|Mac OS X/.test(navigator.userAgent) && !("ontouchend" in document);
      if (!mac) document.body.classList.add("not-mac");
      var add = document.getElementById("add");
      if (add) add.addEventListener("click", function () {
        var left = false;
        function away() { left = true; }
        window.addEventListener("blur", away, { once: true });
        document.addEventListener("visibilitychange", away, { once: true });
        setTimeout(function () { if (!left) document.body.classList.add("maybe-missing"); }, 2500);
      });
    })();
    """
}
