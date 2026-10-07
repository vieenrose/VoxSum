import SwiftUI

/// UI language (Android `AppLanguage`): "system" follows the device; the others force it.
/// The Han script of everything generated follows the UI language, as on Android.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, zhHant = "zh-Hant", zhHans = "zh-Hans"
    var id: String { rawValue }
    var autonym: String { switch self { case .system: return L("lang_system"); case .en: return "English"; case .zhHant: return "繁體中文"; case .zhHans: return "简体中文" } }

    static var current: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }
    /// The concrete interface language (never .system).
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let l = Locale.preferredLanguages.first ?? "en"
        if l.hasPrefix("zh") { return (l.contains("Hans") || l.hasSuffix("-CN") || l.hasSuffix("-SG")) ? .zhHans : .zhHant }
        return .en
    }
    /// Script of generated Chinese text: Simplified for a Simplified UI, Traditional otherwise.
    var script: ChineseScript { resolved == .zhHans ? .simplified : .traditional }
    var bundle: Bundle {
        let dir = resolved == .en ? "en" : resolved.rawValue
        return Bundle.main.path(forResource: dir, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

/// Localised string (String, for statuses too), in the language chosen in Settings.
func L(_ key: String, _ args: CVarArg...) -> String {
    let f = AppLanguage.current.bundle.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? f : String(format: f, arguments: args)
}

/// Persisted tuning (Android ConfigStore subset). Threads: 0 = Auto, else the slider value (2…cores).
enum Prefs {
    /// Experimental, off by default (Android showActionItems).
    static var showActions: Bool { UserDefaults.standard.bool(forKey: "showActions") }
    static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var threads: Int {
        get { UserDefaults.standard.integer(forKey: "threads") }
        set { UserDefaults.standard.set(newValue, forKey: "threads") }
    }
    /// Auto: the benchmark's pick for this phone + app version (Android HwInfo), else the topology heuristic.
    static var effectiveThreads: Int { threads > 0 ? min(max(2, threads), cores) : (benchThreads ?? min(4, max(2, cores - 2))) }
    private static var benchKey: String { "\(cores)|" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") }
    static var benchThreads: Int? {
        let d = UserDefaults.standard
        guard d.string(forKey: "benchKey") == benchKey else { return nil }
        let n = d.integer(forKey: "benchThreads"); return n > 0 ? min(max(2, n), cores) : nil
    }
    /// Runs ThreadBench on every count 2…cores and stores the pick (Settings → Recommended).
    static func runBench() async -> Int? {
        let scores = await Task.detached(priority: .userInitiated) { ThreadBench.run(Array(2...max(2, cores))) }.value
        guard let n = ThreadBench.pick(scores) else { return nil }
        UserDefaults.standard.set(benchKey, forKey: "benchKey"); UserDefaults.standard.set(n, forKey: "benchThreads")
        return n
    }
    /// Live speaker delay (Android speakerDelaySec): how long a line waits before the live view freezes it with its speaker.
    static var speakerDelay: Int {
        get { let v = UserDefaults.standard.integer(forKey: "speakerDelay"); return v == 0 ? 15 : min(30, max(5, v)) }
        set { UserDefaults.standard.set(newValue, forKey: "speakerDelay") }
    }
    /// Text size: 0 follows the system, else a fixed Dynamic Type step.
    static let textSizeLabels = ["text_size_system", "text_size_small", "text_size_normal", "text_size_large", "text_size_xlarge"]
    static func typeSize(_ i: Int) -> DynamicTypeSize? { [nil, .small, .large, .xxLarge, .accessibility1][min(max(i, 0), 4)] }
    /// E4B needs the 8 GB class of phone, as on Android.
    static var e4bAllowed: Bool { ProcessInfo.processInfo.physicalMemory >= 7 << 30 }
    static var readerId: String {
        get { let v = UserDefaults.standard.string(forKey: "reader") ?? "E2B"; return v == "E4B" && e4bAllowed ? v : "E2B" }
        set { UserDefaults.standard.set(newValue, forKey: "reader") }
    }
    static var reader: ReaderModel { readerId == "E4B" ? .e4b : .e2b }
}

/// Appearance (Android theme: Auto / Light / Dark; no e-ink on iOS).
enum Theme: String, CaseIterable, Identifiable {
    case auto, light, dark, eink
    var id: String { rawValue }
    var label: String { L("theme_" + rawValue) }
    var scheme: ColorScheme? { switch self { case .auto: return nil; case .light, .eink: return .light; case .dark: return .dark } }
}

/// Android EinkColors: a manual, flat, high-contrast light theme — black accent, bold legibility, no animation.
struct ThemeStyle: ViewModifier {
    let theme: Theme
    func body(content: Content) -> some View {
        if theme == .eink {
            content.tint(.black).environment(\.legibilityWeight, .bold).transaction { $0.disablesAnimations = true; $0.animation = nil }
        } else { content }
    }
}

/// What the app keeps on disk (Android Storage section): each model folder with its size, deletable.
enum Storage {
    struct Item: Identifiable { let url: URL; let bytes: Int64; var id: String { url.path }; var name: String { url.lastPathComponent }
        var kind: String { let n = name.lowercased(); return n.contains("asr") || n.contains("diariz") || n.contains("nemotron") ? "model_kind_asr" : (n.contains("gemma") || n.contains("mfa") || n.contains("litert") || n.contains("reader") || n.hasSuffix(".litertlm") ? "model_kind_llm" : "model_kind_other") } }
    static var modelsRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("models") }
    static func size(_ u: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return e.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0) { $0 + Int64($1) }
    }
    static func models() -> [Item] {
        let d = (try? FileManager.default.contentsOfDirectory(at: modelsRoot, includingPropertiesForKeys: nil)) ?? []
        return d.map { Item(url: $0, bytes: size($0)) }.sorted { $0.name < $1.name }
    }
    static func delete(_ i: Item) { try? FileManager.default.removeItem(at: i.url) }
    /// The chosen reader's files are all there (synchronous twin of ModelStore.isComplete).
    static func ready(_ m: ReaderModel) -> Bool {
        m.files.allSatisfy { (try? FileManager.default.attributesOfItem(atPath: modelsRoot.appendingPathComponent(m.id).appendingPathComponent($0.name).path)[.size] as? Int64) == $0.size }
    }
}

/// Android ThreadBench: ~1 s of how well this phone scales across threads. Each worker streams its slice
/// of a buffer larger than the caches with a multiply-add (the engines' memory-bound mat-vec shape).
/// Scores are elements per ms, best of REPS interleaved rounds.
enum ThreadBench {
    private static let elements = 1 << 22, passes = 6, reps = 4

    static func run(_ candidates: [Int]) -> [Int: Double] {
        let a = UnsafeMutablePointer<Float>.allocate(capacity: elements), b = UnsafeMutablePointer<Float>.allocate(capacity: elements)
        defer { a.deallocate(); b.deallocate() }
        for i in 0..<elements { a[i] = Float(i & 1023) * 1e-3; b[i] = 1 - Float(i & 511) * 1e-3 }
        _ = measure(1, a, b)
        var best = Dictionary(uniqueKeysWithValues: candidates.map { ($0, 0.0) })
        for _ in 0..<reps { for n in candidates { best[n] = max(best[n]!, measure(n, a, b)) } }
        return best
    }

    /// The fewest threads within `slack` of the best throughput.
    static func pick(_ scores: [Int: Double], slack: Double = 0.05) -> Int? {
        guard let top = scores.values.max() else { return nil }
        return scores.filter { $0.value >= top * (1 - slack) }.keys.min()
    }

    private static func measure(_ n: Int, _ a: UnsafeMutablePointer<Float>, _ b: UnsafeMutablePointer<Float>) -> Double {
        let sinks = UnsafeMutablePointer<Float>.allocate(capacity: n); defer { sinks.deallocate() }
        let group = DispatchGroup(), t0 = DispatchTime.now().uptimeNanoseconds
        for w in 0..<n {
            group.enter()
            let th = Thread {
                let from = elements * w / n, to = elements * (w + 1) / n
                var acc: Float = 0
                for _ in 0..<passes { for i in from..<to { acc += a[i] * b[i] } }
                sinks[w] = acc; group.leave()
            }
            th.qualityOfService = .userInitiated; th.start()
        }
        group.wait()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return Double(elements * passes) / max(ms, 0.001)
    }
}
