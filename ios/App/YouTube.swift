import Foundation

struct YouTubeVideo: Identifiable, Hashable {
    var id: String { url }
    let title, url, uploader: String
    let durationSec: Int
    var durationText: String {
        guard durationSec > 0 else { return "" }
        return durationSec >= 3600 ? String(format: "%d:%02d:%02d", durationSec / 3600, durationSec % 3600 / 60, durationSec % 60)
                                   : String(format: "%d:%02d", durationSec / 60, durationSec % 60)
    }
}

struct YouTubeAudio { let title, streamUrl, ext: String }

enum YouTubeError: LocalizedError {
    case noStream, live
    var errorDescription: String? { L(self == .live ? "err_youtube_live" : "err_youtube_no_stream") }
}

/// YouTube audio source (port of Android `YouTube`): InnerTube search + player (iOS client, direct audio-only streams),
/// then the same resumable download as podcasts. Like Android, a video gated behind proof-of-origin fails cleanly.
enum YouTube {
    private static let api = "https://www.youtube.com/youtubei/v1"
    private static let key = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
    private static let iosVersion = "20.33.2"
    private static let ua = "com.google.ios.youtube/20.33.2 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    static func looksLikeUrl(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("youtu.be/") || t.hasPrefix("www.youtube.")
    }

    static func videoId(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t.hasPrefix("http") ? t : "https://" + t) else { return nil }
        if (u.host ?? "").contains("youtu.be") { return u.pathComponents.dropFirst().first }
        if let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let p = u.pathComponents
        if let i = p.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }), i + 1 < p.count { return p[i + 1] }
        return nil
    }

    private static func post(_ path: String, _ body: [String: Any], ua: String? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "\(api)/\(path)?key=\(key)&prettyPrint=false")!, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ua { r.setValue(ua, forHTTPHeaderField: "User-Agent") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, _) = try await URLSession.shared.data(for: r)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    static func search(_ query: String) async throws -> [YouTubeVideo] {
        let ctx: [String: Any] = ["client": ["clientName": "WEB", "clientVersion": "2.20241120.01.00", "hl": "en"]]
        let j = try await post("search", ["context": ctx, "query": query.trimmingCharacters(in: .whitespaces), "params": "EgIQAQ%3D%3D"])
        var out: [YouTubeVideo] = []
        func walk(_ n: Any) {
            if let d = n as? [String: Any] {
                if let v = d["videoRenderer"] as? [String: Any], let id = v["videoId"] as? String {
                    let title = ((v["title"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                    let by = ((v["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                    let len = (v["lengthText"] as? [String: Any])?["simpleText"] as? String ?? ""
                    let secs = len.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
                    if !title.isEmpty { out.append(YouTubeVideo(title: title, url: "https://www.youtube.com/watch?v=\(id)", uploader: by, durationSec: secs)) }
                } else { d.values.forEach(walk) }
            } else if let a = n as? [Any] { a.forEach(walk) }
        }
        walk(j)
        return out
    }

    /// Lowest-bitrate audio-only stream (everything is resampled to 16 kHz mono downstream), AAC/M4A preferred (always decodable on iOS).
    static func resolve(_ url: String) async throws -> YouTubeAudio {
        guard let id = videoId(url) else { throw YouTubeError.noStream }
        let ctx: [String: Any] = ["client": ["clientName": "IOS", "clientVersion": iosVersion, "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                                             "osName": "iPhone", "osVersion": "18.3.2.22D82", "hl": "en"]]
        let j = try await post("player", ["context": ctx, "videoId": id, "contentCheckOk": true, "racyCheckOk": true], ua: ua)
        let details = j["videoDetails"] as? [String: Any] ?? [:]
        if details["isLive"] as? Bool == true || details["isLiveContent"] as? Bool == true && (details["lengthSeconds"] as? String) == "0" { throw YouTubeError.live }
        let formats = ((j["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]]) ?? []
        let audio = formats.filter { ($0["mimeType"] as? String ?? "").hasPrefix("audio/mp4") && ($0["url"] as? String) != nil }
        guard let best = audio.min(by: { ($0["averageBitrate"] as? Int ?? $0["bitrate"] as? Int ?? .max) < ($1["averageBitrate"] as? Int ?? $1["bitrate"] as? Int ?? .max) }),
              let s = best["url"] as? String else { throw YouTubeError.noStream }
        let title = (details["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "YouTube audio"
        return YouTubeAudio(title: title, streamUrl: s, ext: "m4a")
    }

    /// Streams the resolved audio into the audio directory (resumable `.part`), 500 MB max like podcasts.
    static func download(_ a: YouTubeAudio, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let ep = Episode(title: a.title, audioUrl: a.streamUrl, published: "", duration: "")
        return try await Podcast.download(ep, name: name, progress: progress, ua: ua)
    }
}
