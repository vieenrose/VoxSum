import SwiftUI
import UIKit

/// CPU / RAM / battery sampler, polled only while a HwStatusLine is on screen (Android HwMonitor).
@MainActor final class HwSampler: ObservableObject {
    @Published var cpu = 0
    @Published var ram = 0
    @Published var battery = -1
    @Published var charging = false
    private var last: (used: UInt32, total: UInt32)?
    private var task: Task<Void, Never>?
    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        task?.cancel()
        task = Task { while !Task.isCancelled { sample(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
    }
    func stop() { task?.cancel() }
    private func sample() {
        var info = host_cpu_load_info(); var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) } }
        if ok == KERN_SUCCESS {
            let t = info.cpu_ticks; let used = t.0 + t.1 + t.3, total = used + t.2
            if let l = last, total > l.total { cpu = Int(100 * Double(used - l.used) / Double(total - l.total)) }
            last = (used, total)
        }
        var vm = vm_statistics64(); var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
        if r == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let used = (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
            ram = min(100, Int(100 * Double(used) / Double(ProcessInfo.processInfo.physicalMemory)))
        }
        let b = UIDevice.current.batteryLevel; battery = b < 0 ? -1 : Int(b * 100)
        charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }
}

/// `CPU ▬▬▭ RAM ▬▭▭ BAT ▬▬▬` hairline gauges; red only when worth acting on (>90 %, battery <15 % off charger).
struct HwStatusLine: View {
    @AppStorage("hwMonitor") private var on = true
    @StateObject private var s = HwSampler()
    var body: some View {
        if on {
            HStack(spacing: 8) {
                gauge("CPU", s.cpu, s.cpu > 90)
                gauge("RAM", s.ram, s.ram > 90)
                if s.battery >= 0 { gauge(s.charging ? "BAT +" : "BAT", s.battery, !s.charging && s.battery < 15) }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(L("hw_status_cd", s.cpu, s.ram, max(0, s.battery)))
            .onAppear { s.start() }.onDisappear { s.stop() }
        }
    }
    private func gauge(_ label: String, _ pct: Int, _ alert: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                GeometryReader { g in Capsule().fill(alert ? Color.red : Color.secondary).frame(width: g.size.width * CGFloat(min(100, max(0, pct))) / 100) }
            }.frame(width: 16, height: 2)
        }
    }
}
