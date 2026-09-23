import Foundation
import UIKit

/// The one VM of the app, shared by the Ubuntu (terminal) and Desktop tabs.
///
/// Resume-where-you-left-off: when iOS sends the app to the background the
/// VM is paused (QMP `stop`) and its full state — RAM, CPU, devices — is
/// written into the root qcow2 as internal snapshot `ios-autosave`
/// (`savevm`), inside a background task. Coming back to the foreground just
/// continues (`cont`). If iOS killed the app meanwhile, the next launch
/// starts QEMU with `-loadvm ios-autosave` instead of booting, and you are
/// back where you were in seconds, open programs and all.
///
/// Measured with qemu-system-aarch64 8.2 on the same machine config: savevm
/// of a 2 GiB guest 2.9 s (393 MiB of state), -loadvm to SSH login 8.4 s,
/// versus ~2.5 min for a cold boot.
@MainActor
public final class LinuxVMController {
    public enum State: Equatable, Sendable {
        case idle, installing, booting, restoring, ready, paused, stopped
    }

    public static let shared = LinuxVMController()

    public static let username = "ubuntu"
    public static let passwordKey = "LinuxVM.password"
    static let snapshotTag = "ios-autosave"
    private static let readyMarker = "IOS-VM-READY"

    public private(set) var state = State.idle {
        didSet {
            guard state != oldValue else { return }
            stateObservers.values.forEach { $0(state) }
        }
    }

    public let profile: DeviceProfile
    public private(set) var configuration: VMConfiguration
    let store = ImageStore()

    var password: String {
        UserDefaults.standard.string(forKey: Self.passwordKey) ?? "ubuntu"
    }

    private lazy var serial = SerialConsole(port: configuration.serialPort)
    private lazy var qmp = QMPClient(port: configuration.qmpPort)
    private(set) lazy var shell = GuestShell(port: Int(configuration.sshPort), username: Self.username, password: password)

    private var consoleObservers: [UUID: (Data) -> Void] = [:]
    private var stateObservers: [UUID: (State) -> Void] = [:]
    private var consoleHistory = Data()
    private var serialTail = ""
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private init() {
        profile = DeviceProfile.current()
        configuration = VMConfiguration.recommended()
        let center = NotificationCenter.default
        // Synchronously (queue: .main): the background task has to be
        // requested before this notification returns, or iOS may suspend
        // the app before the snapshot even starts.
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LinuxVMController.shared.enterBackground() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Self.onMain { $0.enterForeground() }
        }
    }

    // MARK: - Observing

    /// Console text (status lines + serial console bytes). Replays what was
    /// printed so far, so a view created later still sees the boot log.
    @discardableResult
    public func observeConsole(_ handler: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        consoleObservers[id] = handler
        if !consoleHistory.isEmpty { handler(consoleHistory) }
        return id
    }

    @discardableResult
    public func observeState(_ handler: @escaping (State) -> Void) -> UUID {
        let id = UUID()
        stateObservers[id] = handler
        handler(state)
        return id
    }

    public func removeObserver(_ id: UUID) {
        consoleObservers[id] = nil
        stateObservers[id] = nil
    }

    func status(_ text: String) {
        emit(Data(("\u{1B}[1;36m" + text.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1B}[0m\r\n").utf8))
    }

    private func emit(_ data: Data) {
        consoleHistory.append(data)
        if consoleHistory.count > 512 * 1024 {
            consoleHistory = consoleHistory.suffix(256 * 1024)
        }
        consoleObservers.values.forEach { $0(data) }
    }

    func sendToSerial(_ data: Data) {
        serial.send(data)
    }

    // MARK: - Lifecycle

    /// Idempotent: installs if needed, then restores the snapshot or boots.
    public func start() {
        guard state == .idle else { return }
        Task { await launch() }
    }

    private func launch() async {
        status(UbuntuRelease.name)
        status("Device: \(profile.name) — vCPUs \(configuration.cpuCount), RAM \(configuration.memoryMiB) MiB, disk \(configuration.diskSize >> 30) GiB")

        guard let selection = QEMURuntime.selectBackend() else {
            if QEMURuntime.framework(named: "qemu-aarch64-softmmu") != nil {
                status("""
                JIT is not enabled for this app, and no interpreter (TCTI) build of QEMU is bundled.
                Enable JIT (e.g. StikDebug / SideStore, or launch from Xcode) and reopen the app.
                """)
            } else {
                status(QEMURuntime.Error.notBundled.localizedDescription)
            }
            state = .stopped
            return
        }
        let (backend, binary) = selection
        status("QEMU backend: \(backend.rawValue)")
        if backend == .interpreter {
            status("Tip: enable JIT for this app for several times more speed.")
        }

        if !store.isInstalled {
            state = .installing
            store.discardSnapshotMarker()
            status("First run: downloading Ubuntu (~750 MB), verifying SHA-256…")
            do {
                try await store.install(diskSize: configuration.diskSize) { progress in
                    let percent = progress.totalBytes > 0 ? Int(progress.receivedBytes * 100 / progress.totalBytes) : 0
                    let line = "  \(progress.fileName): \(percent)%"
                    Self.onMain { $0.showProgress(line) }
                }
                emit(Data("\r\n".utf8))
            } catch {
                status("\nInstall failed: \(error.localizedDescription)\nReopen the app to retry (finished files are kept).")
                state = .stopped
                return
            }
        }

        guard let seed = Bundle.module.url(forResource: "seed", withExtension: "iso") else {
            status("seed.iso missing from the app bundle")
            state = .stopped
            return
        }

        if let marker = store.snapshotMarker() {
            // The snapshot only loads into the machine it was taken on.
            configuration.cpuCount = marker.cpuCount
            configuration.memoryMiB = marker.memoryMiB
            configuration.restoreSnapshot = Self.snapshotTag
            state = .restoring
            status("Resuming from the snapshot saved \(marker.savedAt.formatted(date: .abbreviated, time: .shortened))…")
        } else {
            state = .booting
            status("Booting… (the very first boot runs cloud-init and takes a few minutes under emulation)")
        }

        serial.onData = { data in
            Self.onMain { $0.handleSerial(data) }
        }
        serial.connect()

        let arguments = configuration.arguments(store: store, seedISO: seed, dataDirectory: QEMURuntime.dataDirectory)
        do {
            try QEMURuntime.start(binary: binary, arguments: arguments) { code, fatal in
                Self.onMain { $0.vmExited(status: code, fatal: fatal) }
            }
        } catch {
            status("Could not start QEMU: \(error.localizedDescription)")
            state = .stopped
            return
        }

        Task {
            await qmp.connect()
            if state == .booting {
                // Fresh boot: an old autosave (from before a clean power-off
                // or a failed restore) would only waste disk space.
                _ = try? await qmp.hmp("delvm \(Self.snapshotTag)")
            }
        }

        if state == .restoring {
            // A restored guest is already up — there's no boot marker to
            // wait for, just sshd accepting again.
            do {
                try await shell.waitUntilReachable(timeout: 120)
                await becameReady()
            } catch {
                status("Restored VM is not answering on SSH: \(error.localizedDescription)")
            }
        }
    }

    /// Hops to the main thread in order (unlike separate Tasks), which the
    /// serial byte stream needs.
    nonisolated static func onMain(_ body: @escaping @MainActor (LinuxVMController) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body(LinuxVMController.shared) }
        }
    }

    private var lastProgressLine = ""

    private func showProgress(_ line: String) {
        guard line != lastProgressLine else { return }
        lastProgressLine = line
        emit(Data(("\r\u{1B}[K" + line).utf8))
    }

    private func handleSerial(_ data: Data) {
        emit(data)
        serialTail = String((serialTail + String(decoding: data, as: UTF8.self)).suffix(256))
        if serialTail.contains(Self.readyMarker) {
            serialTail = ""
            if state == .booting {
                Task { await becameReady() }
            }
        }
    }

    private func becameReady() async {
        await syncGuest()
        state = .ready
    }

    /// Clock (frozen while paused/suspended, and the snapshot's time after
    /// a restore) + the tune-up script. Both idempotent and quick.
    func syncGuest() async {
        _ = try? await shell.run("sudo -n date -u -s @\(Int(Date().timeIntervalSince1970)) >/dev/null 2>&1")
        if let tune = Self.bundledScript("guest-tune") {
            _ = try? await shell.run(GuestShell.scriptCommand(tune))
        }
    }

    static func bundledScript(_ name: String) -> String? {
        Bundle.module.url(forResource: name, withExtension: "sh").flatMap { try? String(contentsOf: $0) }
    }

    private func vmExited(status code: Int32, fatal: Bool) {
        let wasRestoring = state == .restoring
        state = .stopped
        shell.close()
        serial.stop()
        qmp.stop()
        if wasRestoring && fatal {
            store.discardSnapshotMarker()
            status("\nThe saved snapshot could not be restored (see above). It has been discarded; reopen the app to boot normally.")
        } else if fatal {
            status("\nQEMU stopped with an error (see output above).")
        } else {
            // Clean power-off: next launch should boot, not resume.
            store.discardSnapshotMarker()
            status("\nThe VM has powered off.")
        }
        status("Close and reopen the app to start it again — QEMU can only run once per app launch.")
    }

    // MARK: - Background / foreground

    private func enterBackground() {
        guard state == .ready else { return }
        state = .paused
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save Ubuntu VM") {
            Self.onMain { $0.endBackgroundTask() }
        }
        let config = configuration
        Task {
            do {
                try await qmp.execute("stop")
                let started = Date()
                try await qmp.hmp("savevm \(Self.snapshotTag)")
                store.writeSnapshotMarker(.init(cpuCount: config.cpuCount, memoryMiB: config.memoryMiB, savedAt: Date()))
                print("LinuxVM: snapshot saved in \(Date().timeIntervalSince(started))s")
            } catch {
                status("Could not save the VM snapshot: \(error.localizedDescription)")
            }
            endBackgroundTask()
        }
    }

    private func enterForeground() {
        guard state == .paused else { return }
        Task {
            _ = try? await qmp.execute("cont")
            await syncGuest()
            state = .ready
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - Snapshot marker

extension ImageStore {
    struct SnapshotMarker: Codable {
        let cpuCount: Int
        let memoryMiB: Int
        let savedAt: Date
    }

    /// Present only after a savevm completed; says which machine config the
    /// snapshot inside disk.qcow2 belongs to.
    var snapshotMarkerURL: URL { directory.appendingPathComponent("snapshot.json") }

    func snapshotMarker() -> SnapshotMarker? {
        guard FileManager.default.fileExists(atPath: diskURL.path),
              let data = try? Data(contentsOf: snapshotMarkerURL) else { return nil }
        return try? JSONDecoder().decode(SnapshotMarker.self, from: data)
    }

    func writeSnapshotMarker(_ marker: SnapshotMarker) {
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: snapshotMarkerURL, options: .atomic)
        }
    }

    func discardSnapshotMarker() {
        try? FileManager.default.removeItem(at: snapshotMarkerURL)
    }
}
