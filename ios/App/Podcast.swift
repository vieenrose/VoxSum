import Foundation

struct PodcastSeries: Identifiable, Hashable { var id: String { feedUrl }; let title, artist, feedUrl: String; let episodeCount: Int }
struct Episode: Identifiable, Hashable { var id: String { audioUrl }; let title, audioUrl, published, duration: String }

/// Podcast input (port of Android `Podcast`): iTunes Search API (no key) → RSS episodes (XMLParser) → enclosure download.
enum Podcast {
    static let maxBytes: Int64 = 500 << 20
    private static let ua = "VoxSum/1.0"

    static func search(_ query: String) async throws -> [PodcastSeries] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: query), .init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"),
                        .init(name: "limit", value: "25"), .init(name: "country", value: "us")]
        let (d, _) = try await URLSession.shared.data(for: request(c.url!))
        let res = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return res.compactMap { o in
            guard let feed = o["feedUrl"] as? String, !feed.isEmpty else { return nil }
            return PodcastSeries(title: o["collectionName"] as? String ?? "Untitled", artist: o["artistName"] as? String ?? "",
                                 feedUrl: feed, episodeCount: o["trackCount"] as? Int ?? 0)
        }
    }

    static func episodes(_ feed: String, limit: Int = 30) async throws -> [Episode] {
        guard let u = URL(string: feed), ["http", "https"].contains(u.scheme) else { throw URLError(.unsupportedURL) }
        let (d, _) = try await URLSession.shared.data(for: request(u))
        let p = RSS(limit: limit), x = XMLParser(data: d); x.delegate = p; x.parse()
        return p.out
    }

    /// Streams the enclosure into the audio directory under `name` (resumable via a `.part` file), 500 MB max.
    static func download(_ ep: Episode, name: String, progress: @escaping @Sendable (Double) -> Void, ua: String? = nil) async throws -> URL {
        guard let u = URL(string: ep.audioUrl), ["http", "https"].contains(u.scheme) else { throw URLError(.unsupportedURL) }
        var head = request(u, ua); head.httpMethod = "HEAD"
        let total = ((try? await URLSession.shared.data(for: head).1) as? HTTPURLResponse)?.expectedContentLength ?? -1
        if total > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        let dest = JobQueue.audioDir.appendingPathComponent(name), part = dest.appendingPathExtension("part")
        let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        try await Chunked.fetch(request(u, ua), to: part, resumeFrom: have) { got in if total > 0 { progress(Double(got) / Double(total)) } }
        let size = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        if size > maxBytes { try? FileManager.default.removeItem(at: part); throw URLError(.dataLengthExceedsMaximum) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
        return dest
    }

    static func ext(_ url: String) -> String {
        let e = (url.split(separator: "?").first.map(String.init) ?? url).split(separator: ".").last.map { String($0.filter { $0.isLetter || $0.isNumber }.prefix(4)) } ?? ""
        return e.isEmpty ? "mp3" : e
    }
    /// "HH:MM:SS" / "MM:SS" stays; plain seconds ("3080") → "51:20".
    static func formatDuration(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let s = Int(t) else { return t }
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    private static func request(_ u: URL, _ agent: String? = nil) -> URLRequest { var r = URLRequest(url: u, timeoutInterval: 15); r.setValue(agent ?? ua, forHTTPHeaderField: "User-Agent"); return r }

    private final class RSS: NSObject, XMLParserDelegate {
        let limit: Int; var out: [Episode] = []
        private var inItem = false, text = "", title = "", audio = "", pub = "", dur = ""
        init(limit: Int) { self.limit = limit }
        func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            text = ""
            if n.lowercased() == "item" { inItem = true; title = ""; audio = ""; pub = ""; dur = "" }
            if inItem, n.lowercased() == "enclosure", audio.isEmpty, (a["type"] ?? "").lowercased().hasPrefix("audio/"), let u = a["url"], !u.isEmpty { audio = u }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, foundCDATA d: Data) { text += String(decoding: d, as: UTF8.self) }
        func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch n.lowercased() {
            case "title" where inItem: title = t
            case "pubdate" where inItem: pub = t
            case "itunes:duration" where inItem: dur = t
            case "item":
                inItem = false
                if !audio.isEmpty { out.append(Episode(title: title.isEmpty ? "Untitled Episode" : title, audioUrl: audio, published: pub, duration: Podcast.formatDuration(dur))) }
                if out.count >= limit { p.abortParsing() }
            default: break
            }
        }
    }
}
