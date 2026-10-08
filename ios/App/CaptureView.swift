import SwiftUI

/// Live recording screen (Android CaptureScreen): big timer, live transcript with a coloured bar per speaker, stop button.
struct CaptureView: View {
    @ObservedObject var m: Model
    private static let palette: [Color] = [.red, .blue, .orange, .green, .purple, .pink, .teal, .indigo]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text(L("status_recording")).font(.title3.weight(.bold)).foregroundStyle(.red)
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 16)
            Text(Export.mmss(Double(m.elapsed))).font(.system(size: 76, weight: .bold, design: .rounded).monospacedDigit())
                .padding(.vertical, 12)
            HwStatusLine().padding(.bottom, 6)
            // The summarizing agent works alongside ASR + diarization: its status stays pinned on top (Android LivePanel).
            AgentStrip(agent: m.agent).padding(.horizontal, 20).padding(.bottom, 6)
                .environment(\.speakerRefs, { [known = Set(m.lines.map(\.speaker))] t in
                    SpeakerRefs.resolve(t, label: { L("speaker_n", $0 + 1) }, known: known.isEmpty ? nil : known) })
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if m.lines.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.secondary)
                                Text(L("capture_live_waiting")).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(m.lines) { l in
                            let c = Self.palette[max(0, l.speaker) % Self.palette.count]
                            HStack(alignment: .top, spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 3)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(L("speaker_n", max(0, l.speaker) + 1)).font(.subheadline.bold()).foregroundStyle(c)
                                        Text(Export.mmss(l.start)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(l.text)
                                }
                            }.id(l.id)
                        }
                    }.padding(.horizontal, 20)
                }
                .onChange(of: m.lines.count) { _, _ in if let id = m.lines.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            Button { m.nextTalk() } label: {
                Label(L("capture_next_talk"), systemImage: "forward.end.fill").font(.headline).accessibilityLabel(L("cd_next_talk"))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }.padding(.horizontal, 20)
            Button { m.toggleRecord() } label: {
                Label(L("capture_stop"), systemImage: "stop.fill").font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
    }
}
