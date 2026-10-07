import SwiftUI

/// Home screen (Android library): search, filter chips, sessions grouped by day as cards, row menu, queue link, record button.
struct LibraryView: View {
    @ObservedObject var m: Model
    @Binding var path: [Session]
    let onAdd: () -> Void
    let onSettings: () -> Void
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var renaming: Session?
    @State private var deleting: Session?
    @State private var draft = ""
    @State private var selected = Set<UUID>()
    @State private var deletingMany = false
    @State private var sharing: URL?
    @AppStorage("seenSessions") private var seenRaw = ""

    enum Filter: String, CaseIterable { case all, new, done }
    private var seen: Set<String> { Set(seenRaw.split(separator: ",").map(String.init)) }
    static func markSeen(_ id: UUID) {
        var s = Set((UserDefaults.standard.string(forKey: "seenSessions") ?? "").split(separator: ",").map(String.init))
        s.insert(id.uuidString); UserDefaults.standard.set(s.joined(separator: ","), forKey: "seenSessions")
    }
    /// Android: NEW = recorded but not yet processed. Archived sessions are all processed (waiting jobs show in the queue line), so they are Done.
    private func isNew(_ s: Session) -> Bool { false }
    private var shown: [Session] {
        m.sessions.filter { s in
            switch filter { case .all: true; case .new: isNew(s); case .done: !isNew(s) }
        }.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }
    private var days: [(Date, [Session])] {
        let g = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
        return g.keys.sorted(by: >).map { ($0, g[$0]!) }
    }
    private func label(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return L("today") }
        if Calendar.current.isDateInYesterday(d) { return L("yesterday") }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
    private func chip(_ f: Filter) -> some View {
        let n = f == .all ? m.sessions.count : m.sessions.filter { f == .new ? isNew($0) : !isNew($0) }.count
        return Button { filter = f } label: {
            Text(L("filter_" + f.rawValue, n)).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(filter == f ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
                .foregroundStyle(filter == f ? Color.white : Color.primary)
        }.buttonStyle(.plain)
    }
    private func card(_ s: Session) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isNew(s) ? "waveform" : "checkmark")
                .font(.title3.weight(.semibold)).frame(width: 40, height: 40)
                .foregroundStyle(isNew(s) ? Color.secondary : Color.green)
                .background((isNew(s) ? Color.secondary : Color.green).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.headline).lineLimit(2)
                Text("\(s.date.formatted(date: .omitted, time: .shortened)) · \(Export.mmss(s.seconds))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !selected.isEmpty {
                Image(systemName: selected.contains(s.id) ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected.contains(s.id) ? Color.accentColor : Color.secondary)
            } else { Menu {
                if let a = s.audio, FileManager.default.fileExists(atPath: JobQueue.audioDir.appendingPathComponent(a).path) {
                    Button(L("action_share_audio"), systemImage: "square.and.arrow.up") { sharing = JobQueue.audioDir.appendingPathComponent(a) }
                }
                Button(L("rename"), systemImage: "pencil") { draft = s.title; renaming = s }
                Button(L("delete"), systemImage: "trash", role: .destructive) { deleting = s }
            } label: { Image(systemName: "ellipsis").padding(10).contentShape(Rectangle()) }
                .accessibilityLabel(L("more")) }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: selected.contains(s.id) ? 2 : 0))
        .contentShape(Rectangle())
        .onLongPressGesture { toggle(s) }
        .onTapGesture { if !selected.isEmpty { toggle(s); return }; Self.markSeen(s.id); seenRaw = UserDefaults.standard.string(forKey: "seenSessions") ?? ""; path.append(s) }
    }

    private func toggle(_ s: Session) { if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) } }

    private func pillar(_ icon: String, _ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 32, height: 32).background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(L(key + "_title")).font(.subheadline.weight(.semibold))
                Text(L(key + "_desc")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if !selected.isEmpty {
                HStack(spacing: 16) {
                    Button { selected = [] } label: { Image(systemName: "xmark").font(.title3) }.accessibilityLabel(L("cd_exit_selection"))
                    Text(L("selection_count", selected.count)).font(.title3.bold())
                    Spacer()
                    Button(L("select_all")) { selected = Set(shown.map(\.id)) }
                    Button(role: .destructive) { deletingMany = true } label: { Image(systemName: "trash").font(.title3) }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            } else {
            HStack {
                Image(systemName: "waveform").font(.headline).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                Text("VoxSum").font(.title2.bold())
                Spacer()
                Button(action: onAdd) { Image(systemName: "plus").font(.title3) }.accessibilityLabel(L("import_audio"))
                Button(action: onSettings) { Image(systemName: "slider.horizontal.3").font(.title3) }.accessibilityLabel(L("settings")).padding(.leading, 12)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("search_sessions"), text: $query)
            }.padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(Filter.allCases.filter { $0 == .all || !m.sessions.isEmpty && ($0 == .done || m.sessions.contains { isNew($0) }) }, id: \.self) { chip($0) } }.padding(.horizontal, 16)
            }.padding(.vertical, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if m.sessions.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.white)
                                .frame(width: 72, height: 72).background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 20))
                            Text(L("empty_headline")).font(.title3.bold()).multilineTextAlignment(.center)
                            Text(L("empty_subtitle")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            VStack(alignment: .leading, spacing: 12) {
                                pillar("lock.fill", "pillar_private")
                                pillar("icloud.slash.fill", "pillar_offline")
                                pillar("banknote.fill", "pillar_cost")
                            }.padding(.top, 6)
                        }.frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if !m.sessions.isEmpty && days.isEmpty { Text(L("studio_no_match")).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40) }
                    ForEach(days, id: \.0) { day, items in
                        Text(label(day)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(items) { card($0) }
                    }
                }.padding(.horizontal, 16)
            }
            if m.pending > 0 {
                HStack { Image(systemName: "list.bullet.below.rectangle"); Text(L("queue_n", m.pending)).font(.subheadline.weight(.semibold)); Spacer() }
                    .foregroundStyle(Color.accentColor).padding(.horizontal, 20).padding(.vertical, 8)
            }
            Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 16)
            Button { m.toggleRecord() } label: {
                Label(m.recording ? L("stop") : L("record"), systemImage: m.recording ? "stop.fill" : "mic.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(m.recording ? Color.red : Color.accentColor, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .alert(L("rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("title"), text: $draft)
            Button(L("done")) { if var s = renaming, !draft.trimmingCharacters(in: .whitespaces).isEmpty { s.title = draft; m.update(s) } }
            Button(L("cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("delete_confirm_many", selected.count), isPresented: $deletingMany, titleVisibility: .visible) {
            Button(L("delete"), role: .destructive) { for s in m.sessions where selected.contains(s.id) { m.remove(s) }; selected = [] }
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) { if let sharing { ShareSheet(url: sharing) } }
        .confirmationDialog(L("delete_confirm", deleting?.title ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("delete"), role: .destructive) { if let s = deleting { m.remove(s) } }
        }
    }
}

/// "Add audio" bottom sheet (Android AddSourceSheet). YouTube and "open session" rows are added when those features exist.
struct AddSourceSheet: View {
    let onFile: () -> Void
    let onPodcast: () -> Void
    @Environment(\.dismiss) private var dismiss
    private func row(_ icon: String, _ title: String, _ desc: String, _ action: @escaping () -> Void) -> some View {
        Button { dismiss(); action() } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    Text(desc).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("add_audio")).font(.title3.bold()).padding(.bottom, 8)
            row("folder", L("source_audio_file"), L("source_audio_file_desc"), onFile)
            row("dot.radiowaves.left.and.right", L("source_podcast"), L("source_podcast_desc"), onPodcast)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.top, 24).presentationDetents([.height(280)])
    }
}
