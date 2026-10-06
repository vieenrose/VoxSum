import Foundation

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
