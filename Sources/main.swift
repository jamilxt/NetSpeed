import AppKit
import Darwin
import ServiceManagement

private let showBitsKey = "showsBits"
private let debugLog = ProcessInfo.processInfo.environment["NETSPEED_DEBUG"] != nil

private func dlog(_ message: @autoclosure () -> String) {
    if debugLog { NSLog("NetSpeed: %@", message()) }
}

// MARK: - Speed model

final class SpeedMonitor {
    private(set) var downBPS: Double = 0
    private(set) var upBPS: Double = 0
    private(set) var sessionDown: UInt64 = 0
    private(set) var sessionUp: UInt64 = 0

    func record(deltaDown: UInt64, deltaUp: UInt64, interval: TimeInterval) {
        guard interval > 0.2 else { return }
        downBPS = Double(deltaDown) / interval
        upBPS = Double(deltaUp) / interval
        sessionDown &+= deltaDown
        sessionUp &+= deltaUp
    }
}

// MARK: - Source 1: interface counters via sysctl

/// 64-bit byte counters summed across all interfaces, via the same sysctl
/// source `netstat -ib` uses. getifaddrs() only exposes 32-bit counters here,
/// which wrap every ~4 GB. Cheap enough to poll once per second.
func currentInterfaceBytes() -> (rx: UInt64, tx: UInt64)? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: len)
    let rc = buffer.withUnsafeMutableBytes { buf -> Int32 in
        sysctl(&mib, 6, buf.baseAddress, &len, nil, 0)
    }
    guard rc == 0 else { return nil }

    var rx: UInt64 = 0
    var tx: UInt64 = 0
    buffer.withUnsafeBytes { raw in
        var offset = 0
        while offset < len {
            let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            let msgLen = Int(msg.ifm_msglen)
            guard msgLen > 0, offset + msgLen <= len else { break }
            if msg.ifm_type == UInt8(RTM_IFINFO2) {
                rx &+= msg.ifm_data.ifi_ibytes
                tx &+= msg.ifm_data.ifi_obytes
            }
            offset += msgLen
        }
    }
    return (rx, tx)
}

// MARK: - Source 2: nettop socket statistics

/// One-shot `nettop -l 1` poll: total per-process bytes_in/bytes_out across
/// all sockets (the same source Activity Monitor's Network panel uses).
/// Costs ~0.03s CPU but ~5s wall time per sample, so it's polled from a
/// background loop only on machines where the interface counters misreport.
enum NettopPoll {
    static func pollOnce(completion: @escaping ((inBytes: UInt64, outBytes: UInt64)?) -> Void) {
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            process.arguments = ["-l", "1", "-P", "-x", "-J", "bytes_in,bytes_out"]
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            do { try process.run() } catch {
                dlog("nettop spawn failed: \(error)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            dlog("nettop exit=\(process.terminationStatus) bytes=\(data.count)")

            var inTotal: UInt64 = 0
            var outTotal: UInt64 = 0
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
                guard tokens.count >= 2,
                      let i = UInt64(tokens[tokens.count - 2]),
                      let o = UInt64(tokens[tokens.count - 1]) else { continue }
                inTotal &+= i
                outTotal &+= o
            }
            let result = (inBytes: inTotal, outBytes: outTotal)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Downloads a probe file and returns how many bytes curl actually
    /// received (used to check whether interface counters report inbound
    /// traffic). Returns nil if the download failed or was too small to tell.
    static func probeDownloadSize() -> UInt64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-sS", "--max-time", "5", "-o", "/dev/null",
            "-w", "%{size_download}",
            "https://speed.cloudflare.com/__down?bytes=3000000",
        ]
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let size = UInt64(text), size > 300_000 else { return nil }
        return size
    }
}

// MARK: - Formatting

func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var i = 0
    while value >= 1024 && i < units.count - 1 {
        value /= 1024
        i += 1
    }
    let num = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    return "\(num) \(units[i])"
}

func formatSpeed(bytesPerSecond: Double, bits: Bool) -> String {
    let units = bits ? ["bps", "Kbps", "Mbps", "Gbps"] : ["B/s", "KB/s", "MB/s", "GB/s"]
    let base = bits ? 1000.0 : 1024.0
    var value = max(0, bits ? bytesPerSecond * 8 : bytesPerSecond)
    var i = 0
    while value >= base && i < units.count - 1 {
        value /= base
        i += 1
    }
    if value < 0.005 { return "0 \(units[i])" }
    let num: String
    if value >= 100 { num = String(format: "%.0f", value) }
    else if value >= 10 { num = String(format: "%.1f", value) }
    else { num = String(format: "%.2f", value) }
    return "\(num) \(units[i])"
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Mode { case calibrating, interfaceCounters, socketStats }

    private let monitor = SpeedMonitor()
    private var mode: Mode = .calibrating
    private var interfaceTimer: Timer?
    private var interfacePrev: (bytes: (rx: UInt64, tx: UInt64), at: Date)?
    private var nettopPrev: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    private var nettopFailures = 0
    private var statusItem: NSStatusItem?
    private var paused = false

    private weak var speedHeaderItem: NSMenuItem!
    private weak var sessionItem: NSMenuItem!
    private weak var pauseItem: NSMenuItem!
    private weak var unitsItem: NSMenuItem!
    private weak var loginItem: NSMenuItem!

    private var showsBits: Bool {
        get { UserDefaults.standard.bool(forKey: showBitsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showBitsKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startInterfaceTimer()
        calibrateWithProbe()
        refreshTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        interfaceTimer?.invalidate()
    }

    /// Downloads a probe file and checks whether the interface counters saw
    /// those bytes. If they didn't (virtual NICs, some proxy setups count
    /// inbound traffic nowhere), switch to nettop socket statistics.
    private func calibrateWithProbe() {
        DispatchQueue.global().async { [weak self] in
            let base = currentInterfaceBytes()
            let downloaded = NettopPoll.probeDownloadSize()
            Thread.sleep(forTimeInterval: 1.0) // let counters settle
            let end = currentInterfaceBytes()

            DispatchQueue.main.async {
                guard let self = self, self.mode == .calibrating else { return }
                guard let base = base, let end = end, let downloaded = downloaded else {
                    // Offline or too slow to tell — assume the standard path
                    // and try again later.
                    dlog("calibration inconclusive, retrying in 10 min")
                    self.mode = .interfaceCounters
                    self.scheduleRecalibration()
                    return
                }
                let interfaceDelta = (end.rx >= base.rx ? end.rx - base.rx : 0)
                    + (end.tx >= base.tx ? end.tx - base.tx : 0)
                dlog("calibration: probe=\(downloaded)B interface=\(interfaceDelta)B")
                if interfaceDelta * 2 < downloaded {
                    dlog("calibration: switching to socketStats")
                    self.mode = .socketStats
                    self.interfaceTimer?.invalidate()
                    self.interfaceTimer = nil
                    self.runNettopLoop()
                } else {
                    dlog("calibration: keeping interfaceCounters")
                    self.mode = .interfaceCounters
                }
            }
        }
    }

    private func scheduleRecalibration() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            if self?.mode == .interfaceCounters { self?.calibrateWithProbe() }
        }
    }

    // MARK: Interface-counters mode (1 s cadence)

    private func startInterfaceTimer() {
        guard interfaceTimer == nil else { return }
        interfaceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.interfaceTick()
        }
    }

    private func interfaceTick() {
        guard let now = currentInterfaceBytes() else { return }
        let at = Date()
        if let prev = interfacePrev {
            let dt = at.timeIntervalSince(prev.at)
            let drx = now.rx >= prev.bytes.rx ? now.rx - prev.bytes.rx : 0
            let dtx = now.tx >= prev.bytes.tx ? now.tx - prev.bytes.tx : 0
            applySpeeds(deltaDown: drx, deltaUp: dtx, interval: dt)
        }
        interfacePrev = (now, at)
    }

    // MARK: Socket-stats mode (~5 s cadence)

    private func runNettopLoop() {
        let started = Date()
        NettopPoll.pollOnce { [weak self] result in
            guard let self = self else { return }
            guard let result = result else {
                self.nettopFailures += 1
                dlog("nettop poll failed (\(self.nettopFailures)/3)")
                if self.nettopFailures >= 3 {
                    // nettop stopped cooperating — go back to interface counters
                    self.mode = .interfaceCounters
                    self.startInterfaceTimer()
                } else {
                    self.runNettopLoop()
                }
                return
            }
            self.nettopFailures = 0
            let at = Date()
            if let prev = self.nettopPrev {
                let dt = at.timeIntervalSince(prev.at)
                let dIn = result.inBytes >= prev.inBytes ? result.inBytes - prev.inBytes : 0
                let dOut = result.outBytes >= prev.outBytes ? result.outBytes - prev.outBytes : 0
                self.applySpeeds(deltaDown: dIn, deltaUp: dOut, interval: dt)
            }
            self.nettopPrev = (result.inBytes, result.outBytes, at)
            // Pace the loop: at most one poll every 2 s.
            let delay = max(0, 2.0 - at.timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.runNettopLoop()
            }
        }
    }

    private func applySpeeds(deltaDown: UInt64, deltaUp: UInt64, interval: TimeInterval) {
        dlog(String(format: "speeds down=%lluB up=%lluB over %.2fs", deltaDown, deltaUp, interval))
        monitor.record(deltaDown: deltaDown, deltaUp: deltaUp, interval: interval)
        if !paused { refreshTitle() }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        func addDisabled(_ title: String) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
            return mi
        }

        speedHeaderItem = addDisabled("↓ —   ↑ —")
        sessionItem = addDisabled("Session: ↓ —  ↑ —")
        menu.addItem(.separator())

        let units = NSMenuItem(title: "Show as bits (Mbps)", action: #selector(toggleUnits), keyEquivalent: "")
        units.target = self
        units.state = showsBits ? .on : .off
        menu.addItem(units)
        unitsItem = units

        let pause = NSMenuItem(title: "Pause updates", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NetSpeed", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    // MARK: Menu updates

    func menuWillOpen(_ menu: NSMenu) {
        let down = formatSpeed(bytesPerSecond: monitor.downBPS, bits: showsBits)
        let up = formatSpeed(bytesPerSecond: monitor.upBPS, bits: showsBits)
        speedHeaderItem.title = "↓ \(down)   ↑ \(up)"
        sessionItem.title = "Session: ↓ \(formatBytes(monitor.sessionDown))  ↑ \(formatBytes(monitor.sessionUp))"
        pauseItem.title = paused ? "Resume updates" : "Pause updates"
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
    }

    // MARK: Actions

    @objc private func toggleUnits() {
        showsBits.toggle()
        unitsItem.state = showsBits ? .on : .off
        refreshTitle()
    }

    @objc private func togglePause() {
        paused.toggle()
        statusItem?.button?.appearsDisabled = paused
        if !paused { refreshTitle() }
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "Could not change the Login Item. You can enable it manually in System Settings → General → Login Items."
            alert.runModal()
        }
    }

    // MARK: Title

    private func refreshTitle() {
        guard let button = statusItem?.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let down = formatSpeed(bytesPerSecond: monitor.downBPS, bits: showsBits)
        let up = formatSpeed(bytesPerSecond: monitor.upBPS, bits: showsBits)
        button.attributedTitle = NSAttributedString(
            string: " ↓\(down)  ↑\(up) ",
            attributes: [.font: font]
        )
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
