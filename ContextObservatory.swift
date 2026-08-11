import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit

enum ContextState: String, Codable, CaseIterable, Sendable {
    case observing
    case engaged
    case watching
    case roomActive
    case autonomous
    case away

    var title: String {
        switch self {
        case .observing: return "CALIBRATING"
        case .engaged: return "YOU + MAC"
        case .watching: return "WATCHING / LISTENING"
        case .roomActive: return "ROOM ACTIVE"
        case .autonomous: return "MAC WORKING ALONE"
        case .away: return "QUIET / AWAY"
        }
    }

    var shortTitle: String {
        switch self {
        case .observing: return "CALIBRATING"
        case .engaged: return "ENGAGED"
        case .watching: return "WATCHING"
        case .roomActive: return "ROOM"
        case .autonomous: return "AUTONOMOUS"
        case .away: return "AWAY"
        }
    }

    var symbol: String {
        switch self {
        case .observing: return "scope"
        case .engaged: return "person.crop.circle.badge.checkmark"
        case .watching: return "play.display"
        case .roomActive: return "wave.3.right.circle"
        case .autonomous: return "cpu"
        case .away: return "moon.stars"
        }
    }
}

enum ContextPermissionState: String, Codable, Sendable {
    case available
    case pending
    case denied
    case unavailable
}

struct ContextSignals: Codable, Sendable {
    var camera: ContextPermissionState = .pending
    var microphone: ContextPermissionState = .pending
    var screen: ContextPermissionState = .pending
    var input: ContextPermissionState = .available
    var humanSeen = false
    var animalSeen = false
    var animalKind: String?
    var dominantSound: String?
    var soundConfidence: Double = 0
    var audioApps: [String] = []
    var cpuPercent: Double = 0
    var screenSummary: String?
    var frontmostApp: String = "Unknown"
    var idleSeconds: Double = 0
}

struct ContextHistoryPoint: Identifiable, Codable, Sendable {
    let timestamp: TimeInterval
    let state: ContextState
    let confidence: Double
    let usedBytes: UInt64
    let frontmostApp: String

    var id: TimeInterval { timestamp }
}

struct ContextSnapshot: Sendable {
    var state: ContextState = .observing
    var confidence: Double = 0.35
    var explanation: String = "Collecting enough local evidence to explain this moment."
    var evidence: [String] = ["No context has left this Mac"]
    var signals = ContextSignals()
    var lastObservedAt = Date()
}

private struct VisionHelperResult: Codable {
    let humanSeen: Bool?
    let animalSeen: Bool?
    let animalKind: String?
    let text: String?
}

private struct SoundHelperResult: Codable {
    let label: String?
    let confidence: Double?
}

private final class FixedAudioRing: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float]
    private var cursor = 0
    private var count = 0
    private let targetRate: Double

    init(seconds: Int = 30, sampleRate: Double = 16_000) {
        targetRate = sampleRate
        samples = Array(repeating: 0, count: seconds * Int(sampleRate))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let sourceCount = Int(buffer.frameLength)
        guard sourceCount > 0 else { return }
        let sourceRate = buffer.format.sampleRate
        let step = max(1, Int((sourceRate / targetRate).rounded()))

        lock.lock()
        defer { lock.unlock() }
        var index = 0
        while index < sourceCount {
            samples[cursor] = channel[index]
            cursor = (cursor + 1) % samples.count
            count = min(count + 1, samples.count)
            index += step
        }
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        let start = (cursor - count + samples.count) % samples.count
        if start + count <= samples.count {
            return Array(samples[start..<(start + count)])
        }
        let first = Array(samples[start..<samples.count])
        let secondCount = count - first.count
        return first + Array(samples[0..<secondCount])
    }

    func recentRMS(seconds: Double = 2) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let wanted = min(count, Int(targetRate * seconds))
        guard wanted > 0 else { return 0 }
        var sum = 0.0
        for offset in 0..<wanted {
            let index = (cursor - 1 - offset + samples.count) % samples.count
            let value = Double(samples[index])
            sum += value * value
        }
        return sqrt(sum / Double(wanted))
    }
}

private final class CameraFrameStore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var pixelBuffer: CVPixelBuffer?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        pixelBuffer = imageBuffer
        lock.unlock()
    }

    func latestCGImage() -> CGImage? {
        lock.lock()
        guard let buffer = pixelBuffer else {
            lock.unlock()
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let source = CIImage(cvPixelBuffer: buffer)
        let image = imageContext.createCGImage(source, from: source.extent)
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        pixelBuffer = nil
        lock.unlock()
        return image
    }
}

private final class CameraCaptureController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ContextObservatory.CameraSession", qos: .utility)
    private let frames: CameraFrameStore
    private var session: AVCaptureSession?

    init(frames: CameraFrameStore) {
        self.frames = frames
    }

    deinit {
        if let session, session.isRunning { session.stopRunning() }
    }

    func configure(device: AVCaptureDevice) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let configured = AVCaptureSession()
        configured.sessionPreset = .vga640x480
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(frames, queue: DispatchQueue(label: "ContextObservatory.CameraFrames", qos: .utility))
        guard configured.canAddInput(input), configured.canAddOutput(output) else { return false }
        configured.addInput(input)
        configured.addOutput(output)
        session = configured
        return true
    }

    func capture(_ completion: @escaping @Sendable (CGImage?) -> Void) {
        queue.async { [weak self] in
            guard let self, let session = self.session else {
                completion(nil)
                return
            }
            if !session.isRunning { session.startRunning() }
            self.queue.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else {
                    completion(nil)
                    return
                }
                let image = self.frames.latestCGImage()
                if session.isRunning { session.stopRunning() }
                completion(image)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let session = self?.session, session.isRunning else { return }
            session.stopRunning()
        }
    }
}

private enum ContextStore {
    static var baseURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Memory Widget/Context Observatory", isDirectory: true)
    }

    static var mediaURL: URL { baseURL.appendingPathComponent("Evidence", isDirectory: true) }

    static func prepare() {
        try? FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
    }

    static func timelineURL(for date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return baseURL.appendingPathComponent("context-\(formatter.string(from: date)).jsonl")
    }

    static func append(_ point: ContextHistoryPoint) {
        prepare()
        guard var data = try? JSONEncoder().encode(point) else { return }
        data.append(0x0A)
        let url = timelineURL()
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch { return }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadRecent(limit: Int = 480) -> [ContextHistoryPoint] {
        let urls = [timelineURL(), timelineURL(for: Date().addingTimeInterval(-86_400))]
        var decoded: [ContextHistoryPoint] = []
        for url in urls.reversed() {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let window = min(size, 384 * 1024)
            try? handle.seek(toOffset: size - window)
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").suffix(limit) {
                if let point = try? JSONDecoder().decode(ContextHistoryPoint.self, from: Data(line.utf8)) {
                    decoded.append(point)
                }
            }
        }
        return Array(decoded.sorted { $0.timestamp < $1.timestamp }.suffix(limit))
    }

    static func pruneRawMedia(olderThan days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let files = try? FileManager.default.contentsOfDirectory(at: mediaURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func logDiagnostic(_ message: String) {
        prepare()
        let url = baseURL.appendingPathComponent("diagnostics.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 64 * 1024 {
            try? data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

@MainActor
final class ContextObservatory: ObservableObject {
    @Published private(set) var snapshot = ContextSnapshot()
    @Published private(set) var history: [ContextHistoryPoint] = ContextStore.loadRecent()
    @Published private(set) var isRunning = false
    @Published private(set) var isPressurePaused = false

    private weak var monitor: MemoryMonitor?
    private let audioEngine = AVAudioEngine()
    private let audioRing = FixedAudioRing()
    private let cameraFrames = CameraFrameStore()
    private lazy var cameraCapture = CameraCaptureController(frames: cameraFrames)
    private var pulseTimer: Timer?
    private var schedulerTimer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var analysisBusy = false
    private var nextScreenAt = Date()
    private var nextCameraAt = Date()
    private var nextSoundAt = Date()
    private var lastHistoryAt = Date.distantPast
    private var lastUsedBytes: UInt64 = 0
    private var lastStateChange = Date.distantPast
    private var lastSummaryAt = Date.distantPast
    private var lastRawPruneAt = Date.distantPast
    private var latestOCR: String?
    private var latestHumanSeen = false
    private var latestAnimalKind: String?
    private var latestSound: String?
    private var latestSoundConfidence = 0.0
    private var latestAudioApps: [String] = []
    private var nextAudioMetadataAt = Date.distantPast
    private var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var screenPermissionAttemptInFlight = false
    private var screenPermissionAttemptedThisLaunch = false

    private enum PermissionDefaults {
        static let cameraPromptAttempted = "ContextObservatory.cameraPromptAttempted"
        static let microphonePromptAttempted = "ContextObservatory.microphonePromptAttempted"
        static let screenCaptureVerified = "ContextObservatory.screenCaptureVerified"
    }

    init(monitor: MemoryMonitor) {
        self.monitor = monitor
        lastUsedBytes = monitor.snapshot.usedBytes
        ContextStore.prepare()
        scheduleNextCaptures(from: Date(), initial: true)
        Task { [weak self] in await self?.start() }
    }

    deinit {
        pulseTimer?.invalidate()
        schedulerTimer?.invalidate()
        pressureSource?.cancel()
        audioEngine.stop()
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        installMemoryPressureMonitor()
        startTimers()

        async let cameraGranted = checkOrRequestPermission(for: .video)
        async let microphoneGranted = checkOrRequestPermission(for: .audio)
        let permissions = await (cameraGranted, microphoneGranted)
        updatePermission(.camera, granted: permissions.0)
        updatePermission(.microphone, granted: permissions.1)

        if permissions.1 { startMicrophone() }
        if permissions.0 { startCamera() }

        // Never request or exercise Screen Recording from the launch path. A
        // preflight result alone is not enough: TCC can retain a stale grant for
        // a rebuilt local app and ScreenCaptureKit will then display another
        // System Settings alert when the first scheduled capture runs. Background
        // capture is armed only after a user-initiated capture succeeds.
        let screenGranted = CGPreflightScreenCaptureAccess()
        let screenVerified = UserDefaults.standard.bool(forKey: PermissionDefaults.screenCaptureVerified)
        if !screenGranted {
            UserDefaults.standard.set(false, forKey: PermissionDefaults.screenCaptureVerified)
        }
        updatePermission(.screen, state: screenGranted && screenVerified ? .available : (screenGranted ? .pending : .denied))
        pulse()
    }

    func stop() {
        pulseTimer?.invalidate()
        schedulerTimer?.invalidate()
        pulseTimer = nil
        schedulerTimer = nil
        audioEngine.stop()
        cameraCapture.stop()
        isRunning = false
    }

    func triggerObservation() {
        nextScreenAt = Date.distantPast
        nextCameraAt = Date.distantPast
        nextSoundAt = Date.distantPast
        schedulerTick()
    }

    func requestScreenPermission() {
        guard !screenPermissionAttemptInFlight, !screenPermissionAttemptedThisLaunch else { return }
        screenPermissionAttemptInFlight = true
        screenPermissionAttemptedThisLaunch = true

        Task { [weak self] in
            guard let self else { return }
            // This app never invokes CGRequestScreenCaptureAccess(). That API can
            // repeatedly offer to open System Settings when TCC retains a stale
            // record for a locally rebuilt app. We only verify an existing grant.
            guard CGPreflightScreenCaptureAccess() else {
                UserDefaults.standard.set(false, forKey: PermissionDefaults.screenCaptureVerified)
                self.updatePermission(.screen, state: .denied)
                self.screenPermissionAttemptInFlight = false
                return
            }

            do {
                _ = try await Self.captureScreenImage()
                UserDefaults.standard.set(true, forKey: PermissionDefaults.screenCaptureVerified)
                self.updatePermission(.screen, state: .available)
                self.nextScreenAt = Date().addingTimeInterval(30)
            } catch {
                UserDefaults.standard.set(false, forKey: PermissionDefaults.screenCaptureVerified)
                ContextStore.logDiagnostic("User-initiated screen permission test failed: \(error.localizedDescription)")
                self.updatePermission(.screen, state: .denied)
            }
            self.screenPermissionAttemptInFlight = false
        }
    }

    private enum PermissionKind { case camera, microphone, screen }

    private func checkOrRequestPermission(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined:
            let key = mediaType == .video
                ? PermissionDefaults.cameraPromptAttempted
                : PermissionDefaults.microphonePromptAttempted
            guard !UserDefaults.standard.bool(forKey: key) else { return false }
            // Persist before invoking TCC so a crash or rebuild cannot turn the
            // collector into a permission-prompt loop.
            UserDefaults.standard.set(true, forKey: key)
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }

    private func updatePermission(_ kind: PermissionKind, granted: Bool) {
        let value: ContextPermissionState = granted ? .available : .denied
        updatePermission(kind, state: value)
    }

    private func updatePermission(_ kind: PermissionKind, state: ContextPermissionState) {
        var signals = snapshot.signals
        switch kind {
        case .camera: signals.camera = state
        case .microphone: signals.microphone = state
        case .screen: signals.screen = state
        }
        snapshot.signals = signals
    }

    private func startTimers() {
        pulseTimer?.invalidate()
        schedulerTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pulse() }
        }
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.schedulerTick() }
        }
    }

    private func startMicrophone() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [audioRing] buffer, _ in
            audioRing.append(buffer)
        }
        do {
            try audioEngine.start()
        } catch {
            updatePermission(.microphone, granted: false)
        }
    }

    private func startCamera() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        let device = discovery.devices.sorted { lhs, rhs in
            let leftScore = lhs.localizedName.localizedCaseInsensitiveContains("Studio Display") ? 0 : (lhs.localizedName.localizedCaseInsensitiveContains("MacBook") ? 1 : 2)
            let rightScore = rhs.localizedName.localizedCaseInsensitiveContains("Studio Display") ? 0 : (rhs.localizedName.localizedCaseInsensitiveContains("MacBook") ? 1 : 2)
            return leftScore < rightScore
        }.first
        guard let device, cameraCapture.configure(device: device) else {
            updatePermission(.camera, granted: false)
            return
        }
    }

    private func installMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.isPressurePaused = true
            self.cameraCapture.stop()
            self.nextScreenAt = Date().addingTimeInterval(10 * 60)
            self.nextCameraAt = Date().addingTimeInterval(10 * 60)
            self.nextSoundAt = Date().addingTimeInterval(10 * 60)
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self else { return }
                self.isPressurePaused = false
                self.scheduleNextCaptures(from: Date(), initial: true)
            }
        }
        source.resume()
        pressureSource = source
    }

    private func pulse() {
        guard isRunning else { return }
        let now = Date()
        let idle = Self.userIdleSeconds()
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let rms = audioRing.recentRMS()
        let cpu = sampleCPUPercent()
        if now >= nextAudioMetadataAt {
            latestAudioApps = Self.activeAudioApplications()
            nextAudioMetadataAt = now.addingTimeInterval(10)
        }
        let memory = monitor?.snapshot ?? MemorySnapshot()
        let delta = Int64(memory.usedBytes) - Int64(lastUsedBytes)
        lastUsedBytes = memory.usedBytes

        let result = inferState(idle: idle, audioRMS: rms, memoryDelta: delta, cpuPercent: cpu, frontApp: frontApp)
        let changed = result.state != snapshot.state
        var signals = snapshot.signals
        signals.frontmostApp = frontApp
        signals.idleSeconds = idle
        signals.humanSeen = latestHumanSeen
        signals.animalSeen = latestAnimalKind != nil
        signals.animalKind = latestAnimalKind
        signals.dominantSound = latestSound
        signals.soundConfidence = latestSoundConfidence
        signals.audioApps = latestAudioApps
        signals.cpuPercent = cpu
        signals.screenSummary = latestOCR

        snapshot = ContextSnapshot(
            state: result.state,
            confidence: result.confidence,
            explanation: result.explanation,
            evidence: result.evidence,
            signals: signals,
            lastObservedAt: now
        )
        MCPStateStore.publish(memory: memory, context: snapshot)

        if changed {
            lastStateChange = now
            nextScreenAt = min(nextScreenAt, now.addingTimeInterval(3))
            nextCameraAt = min(nextCameraAt, now.addingTimeInterval(5))
            nextSoundAt = min(nextSoundAt, now.addingTimeInterval(4))
        }

        if now.timeIntervalSince(lastHistoryAt) >= 15 || changed {
            let point = ContextHistoryPoint(
                timestamp: now.timeIntervalSince1970,
                state: result.state,
                confidence: result.confidence,
                usedBytes: memory.usedBytes,
                frontmostApp: frontApp
            )
            history.append(point)
            if history.count > 480 { history.removeFirst(history.count - 480) }
            ContextStore.append(point)
            lastHistoryAt = now
        }

        if now.timeIntervalSince(lastRawPruneAt) > 6 * 60 * 60 {
            lastRawPruneAt = now
            Task.detached(priority: .background) { ContextStore.pruneRawMedia() }
        }
    }

    private func inferState(idle: Double, audioRMS: Double, memoryDelta: Int64, cpuPercent: Double, frontApp: String) -> (state: ContextState, confidence: Double, explanation: String, evidence: [String]) {
        let heardActivity = audioRMS > 0.012 || latestSoundConfidence > 0.35
        let sound = latestSound?.replacingOccurrences(of: "_", with: " ")
        let activeMemoryShift = abs(memoryDelta) > 48 * 1024 * 1024
        let screen = latestOCR?.trimmingCharacters(in: .whitespacesAndNewlines)

        if idle < 50 {
            var evidence = ["Input detected \(Self.shortDuration(idle)) ago", "Front app: \(frontApp)"]
            if let audioApp = latestAudioApps.first { evidence.insert("Audio from \(audioApp)", at: 1) }
            if let screen, !screen.isEmpty { evidence.append("Screen: \(screen)") }
            return (.engaged, 0.88, "You are actively using \(frontApp); memory changes can be tied to this foreground work.", Array(evidence.prefix(3)))
        }

        if heardActivity && latestHumanSeen {
            let detail = sound.map { "Heard \($0)" } ?? "Audio activity detected"
            let source = latestAudioApps.first.map { "Audio from \($0)" } ?? detail
            return (.watching, 0.82, "Playback or conversation is active while a person remains present.", [source, detail, "Person seen by camera"])
        }

        if heardActivity && latestAnimalKind != nil && !latestHumanSeen {
            return (.roomActive, 0.82, "The room is active without you at the keyboard; this may be playback for \(latestAnimalKind!.lowercased()).", ["\(latestAnimalKind!) seen", sound.map { "Heard \($0)" } ?? "Room audio detected", "No person seen"])
        }

        if idle > 120 && (activeMemoryShift || cpuPercent > 0.18) {
            let activity = activeMemoryShift
                ? "RAM shifted \(ByteCountFormatter.string(fromByteCount: abs(memoryDelta), countStyle: .memory))"
                : "CPU active at \(Int(cpuPercent * 100))%"
            return (.autonomous, 0.78, "The Mac is doing measurable work while no input is occurring, so background activity is running on its own.", ["No input for \(Self.shortDuration(idle))", activity, "Front app remains \(frontApp)"])
        }

        if idle > 10 * 60 && !heardActivity {
            return (.away, 0.86, "The room and Mac appear quiet; retained RAM is mostly keeping prior work ready.", ["No input for \(Self.shortDuration(idle))", "No strong audio event", latestHumanSeen ? "Person was recently seen" : "No person seen recently"])
        }

        return (.observing, 0.56, "The Mac is between clear states; evidence is still being correlated locally.", ["Input idle for \(Self.shortDuration(idle))", "Front app: \(frontApp)", heardActivity ? "Ambient audio activity" : "Low ambient audio"])
    }

    private func schedulerTick() {
        guard isRunning, !isPressurePaused, !analysisBusy else { return }
        let now = Date()
        if now >= nextScreenAt, snapshot.signals.screen == .available {
            captureAndAnalyzeScreen()
            nextScreenAt = now.addingTimeInterval(Double.random(in: 30...90))
        } else if now >= nextCameraAt, snapshot.signals.camera == .available {
            captureAndAnalyzeCamera()
            nextCameraAt = now.addingTimeInterval(Double.random(in: 45...120))
        } else if now >= nextSoundAt, snapshot.signals.microphone == .available {
            captureAndAnalyzeSound()
            nextSoundAt = now.addingTimeInterval(Double.random(in: 60...120))
        }
    }

    private func scheduleNextCaptures(from date: Date, initial: Bool) {
        nextScreenAt = date.addingTimeInterval(initial ? 8 : Double.random(in: 30...90))
        nextCameraAt = date.addingTimeInterval(initial ? 12 : Double.random(in: 45...120))
        nextSoundAt = date.addingTimeInterval(initial ? 18 : Double.random(in: 60...120))
    }

    private func captureAndAnalyzeScreen() {
        guard UserDefaults.standard.bool(forKey: PermissionDefaults.screenCaptureVerified),
              CGPreflightScreenCaptureAccess() else {
            UserDefaults.standard.set(false, forKey: PermissionDefaults.screenCaptureVerified)
            updatePermission(.screen, state: .denied)
            return
        }
        analysisBusy = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await Self.captureScreenImage()
                self.updatePermission(.screen, granted: true)
                let url = self.evidenceURL(kind: "screen", extension: "jpg")
                guard Self.writeJPEG(image, to: url, maxDimension: 1440, quality: 0.58) else {
                    self.analysisBusy = false
                    return
                }
                let result = await Self.runHelper(named: "ContextVisionHelper", arguments: ["screen", url.path])
                self.applyVisionResult(result)
            } catch {
                ContextStore.logDiagnostic("Screen capture failed: \(error.localizedDescription)")
                // One failed capture opens the circuit permanently. There is no
                // automatic retry; only a deliberate SCREEN click can re-arm it.
                UserDefaults.standard.set(false, forKey: PermissionDefaults.screenCaptureVerified)
                self.updatePermission(.screen, state: .denied)
                self.analysisBusy = false
            }
        }
    }

    private func captureAndAnalyzeCamera() {
        analysisBusy = true
        cameraCapture.capture { [weak self] image in
            guard let image else {
                Task { @MainActor [weak self] in self?.analysisBusy = false }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let url = self.evidenceURL(kind: "camera", extension: "jpg")
                guard Self.writeJPEG(image, to: url, maxDimension: 640, quality: 0.58) else {
                    self.analysisBusy = false
                    return
                }
                let result = await Self.runHelper(named: "ContextVisionHelper", arguments: ["camera", url.path])
                self.applyVisionResult(result)
            }
        }
    }

    private func captureAndAnalyzeSound() {
        let samples = audioRing.snapshot()
        guard !samples.isEmpty else { return }
        let url = evidenceURL(kind: "audio", extension: "m4a")
        guard Self.writeAudio(samples, to: url) else { return }
        analysisBusy = true
        Task { [weak self] in
            let result = await Self.runHelper(named: "ContextSoundHelper", arguments: [url.path])
            self?.applySoundResult(result)
        }
    }

    private func applyVisionResult(_ data: Data?) {
        defer { analysisBusy = false }
        guard let data, let result = try? JSONDecoder().decode(VisionHelperResult.self, from: data) else { return }
        if let humanSeen = result.humanSeen { latestHumanSeen = humanSeen }
        if let animalSeen = result.animalSeen {
            latestAnimalKind = animalSeen ? (result.animalKind ?? "Animal") : nil
        }
        if let text = result.text, !text.isEmpty {
            latestOCR = String(text.prefix(110))
        }
        pulse()
    }

    private func applySoundResult(_ data: Data?) {
        defer { analysisBusy = false }
        guard let data, let result = try? JSONDecoder().decode(SoundHelperResult.self, from: data) else { return }
        latestSound = result.label
        latestSoundConfidence = result.confidence ?? 0
        pulse()
    }

    private func evidenceURL(kind: String, extension ext: String) -> URL {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        return ContextStore.mediaURL.appendingPathComponent("\(millis)-\(kind).\(ext)")
    }

    private static func userIdleSeconds() -> Double {
        let keyboard = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        return min(keyboard, mouse, click)
    }

    private func sampleCPUPercent() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let current = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { lastCPUTicks = current }
        guard let previous = lastCPUTicks else { return 0 }
        let busy = (current.user - previous.user) + (current.system - previous.system) + (current.nice - previous.nice)
        let idle = current.idle - previous.idle
        let total = busy + idle
        return total > 0 ? min(1, Double(busy) / Double(total)) : 0
    }

    private static func activeAudioApplications() -> [String] {
        guard #available(macOS 15.0, *) else { return [] }
        let processes = (try? AudioHardwareSystem.shared.processes) ?? []
        var names: [String] = []
        for process in processes where (try? process.isRunningOutput) == true {
            let pid = (try? process.pid) ?? 0
            let bundleID = (try? process.bundleID) ?? ""
            let lowerBundleID = bundleID.lowercased()
            let name: String
            if lowerBundleID.contains("openai.atlas") {
                name = "ChatGPT Atlas"
            } else if lowerBundleID.contains("anthropic") || lowerBundleID.contains("claude") {
                name = "Claude"
            } else if lowerBundleID.contains("openai.chatgpt") || lowerBundleID == "com.openai.codex" {
                name = "ChatGPT"
            } else if lowerBundleID.contains("spotify") {
                name = "Spotify"
            } else if lowerBundleID.contains("safari") {
                name = "Safari"
            } else if lowerBundleID.contains("chrome") {
                name = "Google Chrome"
            } else {
                name = NSRunningApplication(processIdentifier: pid)?.localizedName
                    ?? bundleID.split(separator: ".").last.map(String.init)
                    ?? "Unknown audio app"
            }
            if !names.contains(name) { names.append(name) }
        }
        return Array(names.prefix(4))
    }

    private static func shortDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(max(0, Int(seconds)))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, maxDimension: CGFloat, quality: CGFloat) -> Bool {
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let scale = min(1, maxDimension / max(sourceWidth, sourceHeight))
        let width = max(1, Int(sourceWidth * scale))
        let height = max(1, Int(sourceHeight * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func captureScreenImage() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "ContextObservatory", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let width = min(1440, display.width)
        configuration.width = width
        configuration.height = max(1, Int((Double(display.height) / Double(display.width)) * Double(width)))
        configuration.showsCursor = true
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func writeAudio(_ samples: [Float], to url: URL) -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        do {
            let compressedSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ]
            let file = try AVAudioFile(forWriting: url, settings: compressedSettings)
            try file.write(from: buffer)
            return true
        } catch {
            return false
        }
    }

    private static func runHelper(named name: String, arguments: [String]) async -> Data? {
        await Task.detached(priority: .utility) {
            guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
            let helperURL = executableDirectory.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { return nil }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = helperURL
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return pipe.fileHandleForReading.readDataToEndOfFile()
            } catch {
                return nil
            }
        }.value
    }
}
