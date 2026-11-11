import Foundation

/// How a `SharedMeeting` looks: a web page (`html()`) and an email body (`emailHTML()`), both
/// styled like the Meetings window's chat: the sharer on the right in blue, everyone else on the
/// left in grey. Both end with what tinyMuesli is, for whoever receives them.
extension SharedMeeting {
    public static let website = "https://tinymuesli.com"

    /// One line of the chat: a time after a pause, or a message.
    enum ChatItem: Equatable {
        case divider(Date)
        case message(speaker: String, mine: Bool, startsGroup: Bool, text: String, start: Double)
    }

    var chatItems: [ChatItem] {
        var items: [ChatItem] = []
        var previous: ChatTranscript.Message?
        for message in ChatTranscript.messages(from: transcript.segments) {
            let gap = previous.map { message.start - $0.end >= 120 } ?? true
            if gap { items.append(.divider(transcript.start.addingTimeInterval(message.start))) }
            items.append(.message(speaker: message.speaker, mine: message.speaker == sharedBy,
                                  startsGroup: gap || previous?.speaker != message.speaker,
                                  text: message.text, start: message.start))
            previous = message
        }
        return items
    }

    /// "Zoom · 32 min".
    private var details: [String] {
        var parts: [String] = []
        if let app = transcript.app { parts.append(app) }
        if let end = transcript.end { parts.append(Self.length(end.timeIntervalSince(transcript.start))) }
        return parts
    }

    private var showsNames: Bool { speakers.count > 1 }

    // MARK: - Web page

    public func html() throws -> String {
        let importLink = try importURL().absoluteString
        let iso = ISO8601DateFormatter()
        var chat = ""
        for item in chatItems {
            switch item {
            case .divider(let at):
                chat += "<p class=\"divider\"><time datetime=\"\(iso.string(from: at))\" data-format=\"time\">\(Self.escape(at.formatted(date: .omitted, time: .shortened)))</time></p>\n"
            case let .message(speaker, mine, startsGroup, text, start):
                chat += "<div class=\"msg\(mine ? " me" : "")\(startsGroup ? " first" : "")\">"
                if startsGroup, showsNames, !mine { chat += "<div class=\"who\">\(Self.escape(speaker))</div>" }
                chat += "<div class=\"row\"><p class=\"bubble\">\(Self.escape(text))</p>"
                chat += "<span class=\"at\">\(TranscriptRenderer.timestamp(start))</span></div></div>\n"
            }
        }
        if chat.isEmpty { chat = "<p class=\"divider\">Nobody said anything in this meeting.</p>\n" }

        let tagList = tags.isEmpty ? "" : "<p class=\"tags\">" + tags.map { "#" + Self.escape($0) }.joined(separator: " ") + "</p>"
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
          <h1>\(Self.escape(name))</h1>
          <p class="date"><time datetime="\(iso.string(from: transcript.start))" data-format="date">\(Self.escape(transcript.start.formatted(date: .complete, time: .shortened)))</time></p>
          <p class="details">\(Self.escape((details + [speakers.joined(separator: ", ")]).filter { !$0.isEmpty }.joined(separator: " · ")))</p>
          \(tagList)
          <div class="add">
            <a class="button" id="add" href="\(importLink)">Add to tinyMuesli</a>
            <p class="mac">Shared by \(Self.escape(sharedBy)). With tinyMuesli on your Mac, add the meeting to search it and ask your AI assistant about it.</p>
            <p class="missing">Nothing happened? You may not have tinyMuesli yet. <a href="\(Self.website)">Get it free</a>, then open this page again.</p>
          </div>
          <p class="shared">Shared by \(Self.escape(sharedBy))</p>
        </header>
        <main>
        \(chat)</main>
        <footer>
          <p class="brand">tiny<span>Muesli</span></p>
          <p>Takes notes in your meetings: it notices when a call starts, transcribes it and works out who said what, all on your Mac. Audio never leaves it, and every meeting is plain files you own. Free and open source.</p>
          <a class="button" href="\(Self.website)">Get tinyMuesli for Mac</a>
        </footer>
        <script>\(Self.script)</script>
        </body>
        </html>

        """
    }

    // MARK: - Email

    /// The email body for Mail: inline styles only, since mail apps drop or rewrite style sheets, and
    /// no script. Colours that read on light and dark backgrounds alike, since some mail apps darken
    /// the page and others don't.
    public func emailHTML() throws -> String {
        let importLink = try importURL().absoluteString
        let font = "font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;"
        let secondary = "color:#8e8e93;"
        var chat = ""
        for item in chatItems {
            switch item {
            case .divider(let at):
                chat += "<div style=\"text-align:center;\(secondary)font-size:11px;margin:18px 0 6px\">\(Self.escape(at.formatted(date: .omitted, time: .shortened)))</div>\n"
            case let .message(speaker, mine, startsGroup, text, _):
                chat += "<div style=\"text-align:\(mine ? "right" : "left");margin:\(startsGroup ? 10 : 2)px 0 0\">"
                if startsGroup, showsNames, !mine {
                    chat += "<div style=\"\(secondary)font-size:11px;margin:0 0 2px 12px\">\(Self.escape(speaker))</div>"
                }
                let colours = mine ? "background:#0a84ff;color:#ffffff;" : "background:#e9e9eb;color:#000000;"
                chat += "<span style=\"display:inline-block;max-width:75%;text-align:left;\(colours)border-radius:18px;padding:7px 12px;font-size:15px;line-height:1.35\">\(Self.escape(text))</span></div>\n"
            }
        }
        let date = transcript.start.formatted(date: .complete, time: .shortened)
        let facts = ([date] + details).joined(separator: " · ")
        let tagLine = tags.isEmpty ? "" : "<div style=\"\(secondary)font-size:13px;margin-top:4px\">" + tags.map { "#" + Self.escape($0) }.joined(separator: " ") + "</div>"
        return """
        <html><body style="\(font)">
        <div><br></div>
        <div style="\(font)max-width:640px">
        <div style="border:1px solid #d1d1d6;border-radius:14px;padding:14px 16px;margin:8px 0 16px">
        <div style="\(secondary)font-size:12px">Meeting transcript</div>
        <div style="font-size:20px;font-weight:700;margin:2px 0 4px">\(Self.escape(name))</div>
        <div style="\(secondary)font-size:13px">\(Self.escape(facts))</div>
        <div style="\(secondary)font-size:13px">\(Self.escape(speakers.joined(separator: ", ")))</div>
        \(tagLine)
        <div style="margin-top:12px"><a href="\(importLink)" style="display:inline-block;background:#0a84ff;color:#ffffff;border-radius:999px;padding:8px 16px;font-size:14px;font-weight:600;text-decoration:none">Add to tinyMuesli</a></div>
        <div style="\(secondary)font-size:12px;margin-top:8px">With tinyMuesli on your Mac, the button adds this meeting to your meetings, to search it and ask your AI assistant about it.</div>
        </div>
        \(chat.isEmpty ? "<div style=\"\(secondary)\">Nobody said anything in this meeting.</div>" : chat)
        <div style="border-top:1px solid #d1d1d6;margin-top:24px;padding-top:12px;\(secondary)font-size:12px;line-height:1.5">
        Transcribed on \(Self.escape(sharedBy))’s Mac by <a href="\(Self.website)" style="color:#0a84ff;text-decoration:none">tinyMuesli</a>, which takes notes in your meetings: it notices when a call starts, transcribes it and works out who said what, all on your Mac. Free and open source, at <a href="\(Self.website)" style="color:#0a84ff;text-decoration:none">tinymuesli.com</a>.
        </div>
        </div>
        </body></html>
        """
    }

    /// The email's subject.
    public var emailSubject: String {
        "\(name) – " + transcript.start.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Helpers

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

    static let style = """
    :root {
      --bg: #ffffff; --fg: #1d1d1f; --muted: #8e8e93; --line: #e5e5ea; --card: #f2f2f7;
      --blue: #0a84ff; --grey: #e9e9eb; --grey-fg: #000000;
      color-scheme: light dark;
    }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #1e1e1e; --fg: #f5f5f7; --muted: #98989d; --line: #38383a; --card: #2c2c2e;
              --grey: #3a3a3c; --grey-fg: #ffffff; }
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--fg);
           font: 15px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", "Segoe UI", Roboto, sans-serif; }
    header, main, footer { max-width: 44rem; margin: 0 auto; padding: 0 16px; }
    header { text-align: center; padding-top: 2.5rem; padding-bottom: .5rem; }
    h1 { font-size: clamp(1.5rem, 5vw, 2rem); line-height: 1.15; letter-spacing: -0.02em; margin: 0 0 .5rem; overflow-wrap: anywhere; }
    .date { font-size: 13px; font-weight: 600; margin: 0; }
    .details, .tags, .shared { font-size: 12px; color: var(--muted); margin: .2rem 0 0; }
    .shared { display: none; }
    .not-mac .shared { display: block; }
    .add { background: var(--card); border-radius: 14px; padding: 16px; margin: 1.25rem auto 0; max-width: 28rem; }
    .add p { margin: .6rem 0 0; color: var(--muted); font-size: 12px; }
    .add .missing { display: none; }
    .maybe-missing .add .missing { display: block; }
    .not-mac .add { display: none; }
    .button { display: inline-block; padding: 8px 18px; border-radius: 999px; font-weight: 600; font-size: 14px;
              text-decoration: none; background: var(--blue); color: #fff; }
    a { color: var(--blue); }
    main { padding-top: .5rem; padding-bottom: 2rem; }
    .divider { text-align: center; color: var(--muted); font-size: 11px; margin: 18px 0 6px; }
    .msg { display: flex; flex-direction: column; align-items: flex-start; margin-top: 2px; }
    .msg.first { margin-top: 10px; }
    .msg.me { align-items: flex-end; }
    .who { font-size: 11px; color: var(--muted); margin: 0 12px 2px; }
    .row { display: flex; align-items: center; gap: 8px; max-width: min(34rem, 80%); }
    .me .row { flex-direction: row-reverse; }
    .bubble { margin: 0; padding: 7px 12px; border-radius: 18px; background: var(--grey); color: var(--grey-fg); overflow-wrap: anywhere; }
    .me .bubble { background: var(--blue); color: #fff; }
    .at { font-size: 11px; color: var(--muted); opacity: 0; white-space: nowrap; font-variant-numeric: tabular-nums; }
    .msg:hover .at { opacity: 1; }
    footer { text-align: center; border-top: 1px solid var(--line); padding-top: 1.5rem; padding-bottom: 3rem; }
    footer p { color: var(--muted); font-size: 13px; margin: 0 auto 1rem; max-width: 30rem; }
    footer .brand { color: var(--fg); font-weight: 700; font-size: 15px; letter-spacing: -0.01em; margin-bottom: .4rem; }
    .brand span { color: var(--blue); }
    @media print { .add, footer .button, .at { display: none; } .shared { display: block; } }
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
