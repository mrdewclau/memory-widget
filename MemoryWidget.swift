import AppKit
import Darwin
import SwiftUI

// MARK: - Memory model

struct MemorySnapshot: Sendable {
    var totalBytes: UInt64 = 0
    var activeBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var availableBytes: UInt64 = 0
    var apps: [AppFootprint] = []

    var usedBytes: UInt64 {
        min(totalBytes, activeBytes + wiredBytes + compressedBytes)
    }

    var usage: Double {
        ratio(usedBytes)
    }

    var availableRatio: Double {
        ratio(availableBytes)
    }

    var headroom: Headroom {
        if availableRatio >= 0.25 { return .comfortable }
        if availableRatio >= 0.12 { return .moderate }
        return .low
    }

    func ratio(_ bytes: UInt64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytes) / Double(totalBytes), 0), 1)
    }
}

enum Headroom: String, Sendable {
    case comfortable = "GOOD HEADROOM"
    case moderate = "MODERATE HEADROOM"
    case low = "LOW HEADROOM"
}

struct AppFootprint: Identifiable, Sendable {
    let id: String
    let name: String
    let appPath: String?
    let bytes: UInt64
    let processCount: Int
    let explanation: String
    let roles: [ProcessRoleFootprint]
    let provenance: FootprintProvenance

    static func placeholder(_ index: Int) -> AppFootprint {
        AppFootprint(
            id: "placeholder-\(index)",
            name: "Measuring…",
            appPath: nil,
            bytes: 0,
            processCount: 0,
            explanation: "Grouping related app processes",
            roles: [],
            provenance: .measuring
        )
    }
}

enum ProvenanceConfidence: String, Sendable {
    case confirmed = "CONFIRMED SOURCE"
    case system = "SYSTEM SOURCE"
    case inferred = "LIKELY SOURCE"
    case unknown = "SOURCE UNCLEAR"

    var symbol: String {
        switch self {
        case .confirmed: return "checkmark.shield.fill"
        case .system: return "apple.logo"
        case .inferred: return "sparkles"
        case .unknown: return "questionmark.diamond.fill"
        }
    }
}

struct ProvenanceNode: Identifiable, Sendable {
    let id: String
    let title: String
    let appPath: String?
    let symbol: String
    let detail: String
}

struct FootprintProvenance: Sendable {
    let plainLanguage: String
    let whyItExists: String
    let nodes: [ProvenanceNode]
    let confidence: ProvenanceConfidence
    let evidence: String
    let runningSeconds: UInt64?

    static let measuring = FootprintProvenance(
        plainLanguage: "Identifying what started this…",
        whyItExists: "Tracing its source and purpose",
        nodes: [],
        confidence: .unknown,
        evidence: "Waiting for process evidence",
        runningSeconds: nil
    )
}

private struct ProcessSample: Sendable {
    let pid: Int32
    let parentPID: Int32
    let elapsedSeconds: UInt64?
    let rssKB: UInt64
    let command: String
}

enum ProcessRole: String, CaseIterable, Sendable {
    case main
    case renderer
    case graphics
    case utility
    case media
    case other

    var title: String {
        switch self {
        case .main: return "Main application"
        case .renderer: return "Windows + content"
        case .graphics: return "Graphics helpers"
        case .utility: return "Utility helpers"
        case .media: return "Audio + media"
        case .other: return "Other processes"
        }
    }

    var explanation: String {
        switch self {
        case .main: return "the app itself + core working data"
        case .renderer: return "open windows, pages + conversation content"
        case .graphics: return "drawing, video + visual compositing"
        case .utility: return "networking, storage + background work"
        case .media: return "audio playback, capture + media work"
        case .other: return "supporting work grouped with this app"
        }
    }

    var symbol: String {
        switch self {
        case .main: return "app.fill"
        case .renderer: return "macwindow.on.rectangle"
        case .graphics: return "sparkles.rectangle.stack.fill"
        case .utility: return "gearshape.2.fill"
        case .media: return "waveform"
        case .other: return "ellipsis"
        }
    }
}

struct ProcessRoleFootprint: Identifiable, Sendable {
    let role: ProcessRole
    let bytes: UInt64
    let processCount: Int

    var id: String { role.rawValue }
}

struct MemoryHistoryPoint: Identifiable, Codable, Sendable {
    let timestamp: TimeInterval
    let usedBytes: UInt64
    let totalBytes: UInt64

    var id: TimeInterval { timestamp }
    var usage: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

private enum MemoryHistoryStore {
    private static let retention: TimeInterval = 24 * 60 * 60

    static var fileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support
            .appendingPathComponent("Memory Widget", isDirectory: true)
            .appendingPathComponent("memory-history.json", isDirectory: false)
    }

    static func load() -> [MemoryHistoryPoint] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let points = try? JSONDecoder().decode([MemoryHistoryPoint].self, from: data) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - retention
        return points.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
    }

    static func save(_ points: [MemoryHistoryPoint]) {
        guard let fileURL else { return }
        let cutoff = Date().timeIntervalSince1970 - retention
        let retained = points.filter { $0.timestamp >= cutoff }
        guard let data = try? JSONEncoder().encode(retained) else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot
    @Published private(set) var history: [MemoryHistoryPoint]

    private var timer: Timer?
    private var sampleInFlight = false
    private var lastFootprintSampleAt = Date.distantPast
    private var lastHistoryPersistAt: TimeInterval = 0
    private let historySampleInterval: TimeInterval = 10
    private let historyPersistInterval: TimeInterval = 30
    private let footprintSampleInterval: TimeInterval = 5

    init() {
        snapshot = Self.sampleSystemMemory(apps: [])
        history = MemoryHistoryStore.load()
        recordHistory(snapshot, force: true)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        snapshot = Self.sampleSystemMemory(apps: snapshot.apps)
        recordHistory(snapshot)
        let now = Date()
        guard !sampleInFlight, now.timeIntervalSince(lastFootprintSampleAt) >= footprintSampleInterval else { return }
        lastFootprintSampleAt = now
        sampleInFlight = true

        Task.detached(priority: .utility) {
            let apps = Self.sampleAppFootprints()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.snapshot = Self.sampleSystemMemory(apps: apps)
                self.sampleInFlight = false
            }
        }
    }

    func persistHistory() {
        MemoryHistoryStore.save(history)
    }

    private func recordHistory(_ snapshot: MemorySnapshot, force: Bool = false) {
        guard snapshot.totalBytes > 0 else { return }
        let now = Date().timeIntervalSince1970
        if !force, let last = history.last, now - last.timestamp < historySampleInterval { return }

        let point = MemoryHistoryPoint(timestamp: now, usedBytes: snapshot.usedBytes, totalBytes: snapshot.totalBytes)
        var updated = history
        if let last = updated.last, now - last.timestamp < 2 {
            updated[updated.count - 1] = point
        } else {
            updated.append(point)
        }

        let cutoff = now - 24 * 60 * 60
        updated.removeAll { $0.timestamp < cutoff }
        history = updated

        if force || now - lastHistoryPersistAt >= historyPersistInterval {
            lastHistoryPersistAt = now
            let pointsToSave = updated
            Task.detached(priority: .background) {
                MemoryHistoryStore.save(pointsToSave)
            }
        }
    }

    nonisolated private static func sampleSystemMemory(apps: [AppFootprint]) -> MemorySnapshot {
        var total: UInt64 = 0
        var totalLength = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &totalLength, nil, 0)

        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS, total > 0 else {
            return MemorySnapshot(totalBytes: total, apps: apps)
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        // These four buckets deliberately reconcile to physical RAM. "Available"
        // includes free, inactive, speculative, and reclaimable file-backed pages.
        let wired = min(UInt64(stats.wire_count) * page, total)
        let compressed = min(UInt64(stats.compressor_page_count) * page, total - wired)
        let active = min(UInt64(stats.active_count) * page, total - wired - compressed)
        let available = total - wired - compressed - active

        return MemorySnapshot(
            totalBytes: total,
            activeBytes: active,
            wiredBytes: wired,
            compressedBytes: compressed,
            availableBytes: available,
            apps: apps
        )
    }

    nonisolated private static func sampleAppFootprints() -> [AppFootprint] {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,etime=,rss=,comm="]
        task.standardOutput = output

        do {
            try task.run()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        struct RoleAccumulator {
            var bytes: UInt64 = 0
            var processCount: Int = 0
        }

        struct Accumulator {
            var name: String
            var appPath: String?
            var bytes: UInt64 = 0
            var processCount: Int = 0
            var roles: [ProcessRole: RoleAccumulator] = [:]
            var representativePID: Int32 = 0
            var representativeBytes: UInt64 = 0
            var longestElapsedSeconds: UInt64?
        }

        var groups: [String: Accumulator] = [:]
        var processes: [Int32: ProcessSample] = [:]

        for line in text.split(separator: "\n") {
            let fields = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 5,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]),
                  let rssKB = UInt64(fields[3]),
                  pid > 0,
                  rssKB > 0 else { continue }

            let elapsedSeconds = parseElapsedTime(String(fields[2]))
            let command = String(fields[4])
            processes[pid] = ProcessSample(
                pid: pid,
                parentPID: parentPID,
                elapsedSeconds: elapsedSeconds,
                rssKB: rssKB,
                command: command
            )
            let bytes = physicalFootprint(for: pid) ?? (rssKB * 1024)
            let name = groupName(for: command)
            let appPath = appBundlePath(for: command)
            let groupID = appPath ?? name
            let role = processRole(for: command, appName: name)

            var group = groups[groupID] ?? Accumulator(name: name, appPath: appPath)
            group.bytes += bytes
            group.processCount += 1
            var roleTotal = group.roles[role] ?? RoleAccumulator()
            roleTotal.bytes += bytes
            roleTotal.processCount += 1
            group.roles[role] = roleTotal
            if bytes > group.representativeBytes {
                group.representativeBytes = bytes
                group.representativePID = pid
            }
            if let elapsedSeconds {
                group.longestElapsedSeconds = max(group.longestElapsedSeconds ?? 0, elapsedSeconds)
            }
            groups[groupID] = group
        }

        return groups.sorted { $0.value.bytes > $1.value.bytes }.prefix(5).map { id, value in
            let roles = ProcessRole.allCases.compactMap { role -> ProcessRoleFootprint? in
                guard let roleTotal = value.roles[role] else { return nil }
                return ProcessRoleFootprint(
                    role: role,
                    bytes: roleTotal.bytes,
                    processCount: roleTotal.processCount
                )
            }
            let provenance = provenance(
                for: value.name,
                appPath: value.appPath,
                processCount: value.processCount,
                representativePID: value.representativePID,
                runningSeconds: value.longestElapsedSeconds,
                processes: processes
            )
            return AppFootprint(
                id: id,
                name: value.name,
                appPath: value.appPath,
                bytes: value.bytes,
                processCount: value.processCount,
                explanation: explanation(for: value.name),
                roles: roles,
                provenance: provenance
            )
        }
    }

    nonisolated private static func parseElapsedTime(_ value: String) -> UInt64? {
        let dayParts = value.split(separator: "-", maxSplits: 1).map(String.init)
        let days: UInt64
        let clock: String
        if dayParts.count == 2 {
            days = UInt64(dayParts[0]) ?? 0
            clock = dayParts[1]
        } else {
            days = 0
            clock = value
        }

        let components = clock.split(separator: ":").compactMap { UInt64($0) }
        guard components.count == 2 || components.count == 3 else { return nil }
        let hours = components.count == 3 ? components[0] : 0
        let minutes = components.count == 3 ? components[1] : components[0]
        let seconds = components.count == 3 ? components[2] : components[1]
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    nonisolated private static func physicalFootprint(for pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0, info.ri_phys_footprint > 0 else { return nil }
        return info.ri_phys_footprint
    }

    nonisolated private static func groupName(for command: String) -> String {
        let components = command.split(separator: "/").map(String.init)
        if let appComponent = components.first(where: { $0.hasSuffix(".app") }) {
            return String(appComponent.dropLast(4))
        }

        let executable = (command as NSString).lastPathComponent
        let lower = executable.lowercased()

        if lower.contains("chatgpt atlas") { return "ChatGPT Atlas" }
        if lower.contains("chatgpt") { return "ChatGPT" }
        if lower.contains("claude") { return "Claude" }
        if lower.contains("codex") { return "Codex" }
        if lower.contains("google chrome") { return "Google Chrome" }
        if lower.contains("safari") { return "Safari" }
        if lower.contains("firefox") { return "Firefox" }
        if lower.contains("openandsavepanelservice") { return "Open & Save Panels" }
        if lower.contains("quicklook") { return "Quick Look" }
        if lower.contains("com.apple.virtualization.virtualmachine") { return "Virtual Machine" }

        for suffix in [" Helper (Renderer)", " Helper (GPU)", " Helper", " (Renderer)", " (GPU)"] {
            if executable.hasSuffix(suffix) {
                return String(executable.dropLast(suffix.count))
            }
        }
        return executable.isEmpty ? command : executable
    }

    nonisolated private static func appBundlePath(for command: String) -> String? {
        let components = (command as NSString).pathComponents
        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...appIndex]))
    }

    nonisolated private static func processRole(for command: String, appName: String) -> ProcessRole {
        let executable = (command as NSString).lastPathComponent
        let lower = executable.lowercased()
        let normalizedAppName = appName.lowercased().replacingOccurrences(of: " ", with: "")
        let normalizedExecutable = lower.replacingOccurrences(of: " ", with: "")

        if lower.contains("renderer") || lower.contains("web content") || lower.contains("webcontent") {
            return .renderer
        }
        if lower.contains("gpu") || lower.contains("graphics") {
            return .graphics
        }
        if lower.contains("audio") || lower.contains("media") {
            return .media
        }
        if lower.contains("utility") || lower.contains("helper") || lower.contains("service") ||
            lower.contains("plugin") || lower.contains("alerts") || lower.contains("crashpad") ||
            lower.contains("xpc") || lower.contains("network") || lower.contains("autoupdate") ||
            lower.contains("disclaimer") {
            return .utility
        }
        if normalizedExecutable == normalizedAppName || lower == appName.lowercased() {
            return .main
        }
        return .other
    }

    nonisolated private static func provenance(
        for name: String,
        appPath: String?,
        processCount: Int,
        representativePID: Int32,
        runningSeconds: UInt64?,
        processes: [Int32: ProcessSample]
    ) -> FootprintProvenance {
        let representativeCommand = processes[representativePID]?.command ?? name
        var sourcePath = appPath
        var confidence: ProvenanceConfidence = .confirmed
        var evidence = appPath.map { "Executable is inside \($0)" } ?? ""

        if sourcePath == nil,
           let ancestorPath = ancestryAppPath(startingAt: representativePID, processes: processes) {
            sourcePath = ancestorPath
            evidence = "A parent process belongs to \(ancestorPath)"
        }

        if sourcePath == nil,
           let openFileApp = sourceAppFromOpenFiles(pid: representativePID) {
            sourcePath = openFileApp
            evidence = "This process is using private resources from \(openFileApp)"
        }

        let sourceName = sourcePath.map(appDisplayName)
        let lower = name.lowercased()
        let isSystemOwned = sourcePath == nil && representativeCommand.hasPrefix("/System/")

        if isSystemOwned {
            confidence = .system
            evidence = "Executable is supplied by macOS at \(representativeCommand)"
        } else if sourcePath == nil {
            confidence = .unknown
            evidence = "macOS exposes the process, but not a reliable originating app"
        }

        let nodes: [ProvenanceNode]
        if lower.contains("virtual machine") || lower.contains("virtualization") {
            nodes = [
                ProvenanceNode(
                    id: "source",
                    title: sourceName ?? "Unknown source",
                    appPath: sourcePath,
                    symbol: sourcePath == nil ? "questionmark.app.fill" : "app.fill",
                    detail: evidence
                ),
                ProvenanceNode(
                    id: "virtualization",
                    title: "Apple virtualization",
                    appPath: nil,
                    symbol: "terminal.fill",
                    detail: "macOS creates an isolated software computer for the source app"
                ),
                ProvenanceNode(
                    id: "footprint",
                    title: "Virtual Machine",
                    appPath: nil,
                    symbol: "cube.fill",
                    detail: "This is the process currently holding the displayed memory"
                )
            ]
        } else if let sourceName {
            nodes = [
                ProvenanceNode(
                    id: "source",
                    title: sourceName,
                    appPath: sourcePath,
                    symbol: "app.fill",
                    detail: evidence
                ),
                ProvenanceNode(
                    id: "helpers",
                    title: processCount == 1 ? "Running process" : "\(processCount) processes",
                    appPath: nil,
                    symbol: processCount == 1 ? "gearshape.fill" : "square.stack.3d.up.fill",
                    detail: processCount == 1 ? "One process is contributing to this footprint" : "Related helpers are grouped into one understandable total"
                ),
                ProvenanceNode(
                    id: "footprint",
                    title: "Memory footprint",
                    appPath: nil,
                    symbol: "memorychip.fill",
                    detail: "The combined physical memory currently associated with this app"
                )
            ]
        } else {
            nodes = [
                ProvenanceNode(
                    id: "source",
                    title: isSystemOwned ? "macOS" : "Unknown source",
                    appPath: nil,
                    symbol: isSystemOwned ? "apple.logo" : "questionmark.app.fill",
                    detail: evidence
                ),
                ProvenanceNode(
                    id: "process",
                    title: "Background process",
                    appPath: nil,
                    symbol: "gearshape.2.fill",
                    detail: representativeCommand
                ),
                ProvenanceNode(
                    id: "footprint",
                    title: name,
                    appPath: nil,
                    symbol: "memorychip.fill",
                    detail: "This is the process group currently holding the displayed memory"
                )
            ]
        }

        return FootprintProvenance(
            plainLanguage: plainLanguageExplanation(for: name, processCount: processCount),
            whyItExists: purposeExplanation(for: name, sourceName: sourceName),
            nodes: nodes,
            confidence: confidence,
            evidence: evidence,
            runningSeconds: runningSeconds
        )
    }

    nonisolated private static func ancestryAppPath(
        startingAt pid: Int32,
        processes: [Int32: ProcessSample]
    ) -> String? {
        var currentPID = processes[pid]?.parentPID ?? 0
        var visited: Set<Int32> = []

        for _ in 0..<8 {
            guard currentPID > 1,
                  !visited.contains(currentPID),
                  let process = processes[currentPID] else { return nil }
            visited.insert(currentPID)
            if let path = appBundlePath(for: process.command) { return path }
            currentPID = process.parentPID
        }
        return nil
    }

    nonisolated private static func sourceAppFromOpenFiles(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-Fn", "-p", String(pid)]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") where line.first == "n" {
            let path = String(line.dropFirst())
            guard path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") || path.contains("/Applications/") else { continue }
            if let appPath = appBundlePath(for: path) { return appPath }
        }
        return nil
    }

    nonisolated private static func appDisplayName(_ path: String) -> String {
        let component = (path as NSString).lastPathComponent
        return component.hasSuffix(".app") ? String(component.dropLast(4)) : component
    }

    nonisolated private static func plainLanguageExplanation(for name: String, processCount: Int) -> String {
        let lower = name.lowercased()
        if lower.contains("virtual machine") || lower.contains("virtualization") {
            return "A small computer running inside your Mac."
        }
        if lower.contains("chatgpt") || lower.contains("claude") || lower.contains("codex") {
            return "\(name) and the helpers holding its windows and conversation context."
        }
        if lower.contains("safari") || lower.contains("chrome") || lower.contains("firefox") || lower.contains("arc") {
            return "\(name) and the helpers running its open tabs and extensions."
        }
        if lower.contains("windowserver") {
            return "The macOS service drawing every visible window and display."
        }
        if lower.contains("kernel") {
            return "The core of macOS managing hardware and essential system work."
        }
        if name == "Finder" {
            return "The part of macOS showing your files, folders and desktop."
        }
        let processWord = processCount == 1 ? "process" : "related processes"
        return "\(name) and its \(processWord) currently working on your Mac."
    }

    nonisolated private static func purposeExplanation(for name: String, sourceName: String?) -> String {
        let lower = name.lowercased()
        if lower.contains("virtual machine") || lower.contains("virtualization") {
            if let sourceName { return "Keeps \(sourceName)'s tools and software isolated." }
            return "Keeps another app's tools and software isolated."
        }
        if lower.contains("chatgpt") || lower.contains("claude") || lower.contains("codex") {
            return "Keeps open windows, conversations and background helpers ready."
        }
        if lower.contains("safari") || lower.contains("chrome") || lower.contains("firefox") || lower.contains("arc") {
            return "Keeps tabs responsive and pages ready to display."
        }
        if lower.contains("windowserver") { return "Turns app content into the windows visible on your displays." }
        if lower.contains("kernel") { return "Keeps macOS and the Mac's hardware operating safely." }
        if name == "Finder" { return "Keeps files, folders, previews and the desktop ready." }
        return "Supports the current work performed by \(name)."
    }

    nonisolated private static func explanation(for group: String) -> String {
        let name = group.lowercased()
        if name.contains("chatgpt") || name.contains("claude") || name.contains("codex") {
            return "renderers + loaded conversation context"
        }
        if name.contains("safari") || name.contains("chrome") || name.contains("firefox") || name.contains("arc") {
            return "tabs + extensions + renderer cache"
        }
        if name.contains("xcode") || name.contains("visual studio") || name.contains("code") {
            return "editors + language indexes + previews"
        }
        if name.contains("windowserver") {
            return "desktop windows, displays + visual compositing"
        }
        if name.contains("open & save") {
            return "macOS file-picker windows opened by apps"
        }
        if name.contains("quick look") {
            return "file previews generated for Finder and apps"
        }
        if name.contains("mediaanalysisd") || name.contains("photo") {
            return "photo and media indexing in the background"
        }
        if name.contains("kernel_task") {
            return "core macOS and hardware management"
        }
        if name == "finder" {
            return "files, previews + Finder working data"
        }
        if name.contains("docker") || name.contains("virtual") || name.contains("qemu") {
            return "virtual machines, containers + their working data"
        }
        return "active app data, open documents + working cache"
    }
}

@MainActor
final class WidgetPresentation: ObservableObject {
    @Published var isCollapsed: Bool {
        didSet { UserDefaults.standard.set(isCollapsed, forKey: "widgetCollapsed") }
    }

    init() {
        isCollapsed = UserDefaults.standard.bool(forKey: "widgetCollapsed")
    }
}

@MainActor
final class MenuBarPresentation: ObservableObject {
    @Published var selectedFootprintID: String?

    func reset() {
        selectedFootprintID = nil
    }
}

// MARK: - Visual system

private enum Palette {
    static let ink = Color(red: 0.93, green: 0.95, blue: 0.99)
    static let secondary = Color(red: 0.62, green: 0.68, blue: 0.77)
    static let tertiary = Color(red: 0.43, green: 0.49, blue: 0.58)
    static let panel = Color(red: 0.055, green: 0.067, blue: 0.09)
    static let surface = Color.white.opacity(0.045)
    static let border = Color.white.opacity(0.12)
    static let active = Color(red: 0.31, green: 0.86, blue: 0.76)
    static let wired = Color(red: 0.39, green: 0.58, blue: 0.98)
    static let compressed = Color(red: 0.94, green: 0.66, blue: 0.30)
    static let available = Color(red: 0.27, green: 0.32, blue: 0.40)
}

struct MemoryWidgetView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var observatory: ContextObservatory
    @ObservedObject var presentation: WidgetPresentation
    let onToggleCollapsed: () -> Void
    let onEnterMenuBarMode: () -> Void
    let onContentSizeChange: (CGSize) -> Void
    @State private var expandedFootprintID: String?

    init(
        monitor: MemoryMonitor,
        observatory: ContextObservatory,
        presentation: WidgetPresentation,
        onToggleCollapsed: @escaping () -> Void,
        onEnterMenuBarMode: @escaping () -> Void,
        onContentSizeChange: @escaping (CGSize) -> Void
    ) {
        self.monitor = monitor
        self.observatory = observatory
        self.presentation = presentation
        self.onToggleCollapsed = onToggleCollapsed
        self.onEnterMenuBarMode = onEnterMenuBarMode
        self.onContentSizeChange = onContentSizeChange
        _expandedFootprintID = State(initialValue: nil)
    }

    @ViewBuilder
    var body: some View {
        let snapshot = monitor.snapshot

        if presentation.isCollapsed {
            collapsedView(snapshot)
                .reportContentSize(onContentSizeChange)
        } else {
            expandedView(snapshot)
                .reportContentSize(onContentSizeChange)
        }
    }

    private func expandedView(_ snapshot: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header(snapshot)
                headline(snapshot)
                compositionBar(snapshot)
                breakdown(snapshot)
                MemoryHistoryChart(points: monitor.history, contextPoints: observatory.history, current: snapshot)
                ContextObservatoryCard(observatory: observatory)
            }
            .padding(22)

            Divider().overlay(Palette.border)

            VStack(alignment: .leading, spacing: 14) {
                appSectionHeader

                let rankedApps = displayedApps(snapshot.apps)
                let visibleSelection = rankedApps.contains { $0.id == expandedFootprintID } ? expandedFootprintID : nil
                let arrangedApps = arrangedApps(rankedApps, selectedID: visibleSelection)
                ForEach(arrangedApps, id: \.id) { app in
                    AppFootprintRow(
                        app: app,
                        rank: (rankedApps.firstIndex { $0.id == app.id } ?? 0) + 1,
                        maximumBytes: snapshot.apps.first?.bytes ?? 1,
                        isExpanded: visibleSelection == app.id,
                        isCondensed: visibleSelection != nil && visibleSelection != app.id
                    ) {
                        guard app.processCount > 0 else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedFootprintID = expandedFootprintID == app.id ? nil : app.id
                        }
                    }
                }

                Text(expandedFootprintID == nil
                     ? "App footprints explain ownership and can overlap ACTIVE + COMPRESSED above. The four composition tiles are the exact physical-RAM total."
                     : "This app footprint can overlap ACTIVE + COMPRESSED above. The four composition tiles remain the exact physical-RAM total.")
                    .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .frame(width: 420, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: true)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.border, lineWidth: 1))
        .preferredColorScheme(.dark)
    }

    private func collapsedView(_ snapshot: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            header(snapshot)

            HStack(alignment: .lastTextBaseline, spacing: 16) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(ByteFormatter.gigabytes(snapshot.usedBytes))
                        .font(.system(size: 33, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                    Text("GB USED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(Palette.secondary)
                        .padding(.bottom, 4)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(ByteFormatter.gigabytes(snapshot.availableBytes)) GB")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.active)
                        .monospacedDigit()
                    Text("AVAILABLE")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(Palette.secondary)
                }
            }

            MemoryCompositionBar(snapshot: snapshot, height: 8)

            HStack(spacing: 0) {
                CompactBucket(color: Palette.active, label: "ACTIVE", value: snapshot.activeBytes)
                CompactBucket(color: Palette.wired, label: "SYSTEM", value: snapshot.wiredBytes)
                CompactBucket(color: Palette.compressed, label: "PACKED", value: snapshot.compressedBytes)
                CompactBucket(color: Palette.available, label: "FREE", value: snapshot.availableBytes)
            }

            CompactContextGlance(snapshot: observatory.snapshot)
        }
        .padding(18)
        .frame(width: 360, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: true)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.border, lineWidth: 1))
        .preferredColorScheme(.dark)
    }

    private func header(_ snapshot: MemorySnapshot) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Circle().fill(Palette.active).frame(width: 8, height: 8)
                Text("MEMORY")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(Palette.ink)
            }

            Spacer()

            Text(snapshot.headroom.rawValue)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(headroomColor(snapshot.headroom))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(headroomColor(snapshot.headroom).opacity(0.10))
                .clipShape(Capsule())

            Text("LIVE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(Palette.active)

            HeaderIconButton(
                symbol: presentation.isCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                label: presentation.isCollapsed ? "Expand widget" : "Collapse widget"
            ) {
                onToggleCollapsed()
            }

            HeaderIconButton(symbol: "menubar.rectangle", label: "Move to menu bar") {
                onEnterMenuBarMode()
            }
        }
    }

    private func headline(_ snapshot: MemorySnapshot) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(ByteFormatter.gigabytes(snapshot.usedBytes))
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                    Text("GB")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                        .padding(.bottom, 6)
                }
                Text("USED  ·  \(Int(snapshot.usage * 100))% OF \(ByteFormatter.gigabytes(snapshot.totalBytes)) GB")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(0.75)
                    .foregroundStyle(Palette.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text("\(ByteFormatter.gigabytes(snapshot.availableBytes)) GB")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.active)
                    .monospacedDigit()
                Text("AVAILABLE")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.bottom, 3)
        }
    }

    private func compositionBar(_ snapshot: MemorySnapshot) -> some View {
        MemoryCompositionBar(snapshot: snapshot, height: 10)
    }

    private func breakdown(_ snapshot: MemorySnapshot) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                MemoryDetail(color: Palette.active, title: "ACTIVE", value: snapshot.activeBytes, explanation: "apps + current work")
                MemoryDetail(color: Palette.wired, title: "SYSTEM", value: snapshot.wiredBytes, explanation: "macOS reserved")
            }
            HStack(spacing: 10) {
                MemoryDetail(color: Palette.compressed, title: "COMPRESSED", value: snapshot.compressedBytes, explanation: "inactive data packed")
                MemoryDetail(color: Palette.available, title: "AVAILABLE", value: snapshot.availableBytes, explanation: "free + reclaimable")
            }
        }
    }

    private var appSectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(expandedFootprintID == nil ? "LARGEST APP FOOTPRINTS" : "FOOTPRINT EXPLAINED")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.25)
                .foregroundStyle(Palette.secondary)
            Spacer()
            Text(expandedFootprintID == nil ? "CLICK TO EXPLORE" : "CLICK TO CLOSE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Palette.active)
        }
    }

    private func displayedApps(_ apps: [AppFootprint]) -> [AppFootprint] {
        var result = Array(apps.prefix(5))
        while result.count < 5 {
            result.append(.placeholder(result.count))
        }
        return result
    }

    private func arrangedApps(_ apps: [AppFootprint], selectedID: String?) -> [AppFootprint] {
        guard let selectedID,
              let selected = apps.first(where: { $0.id == selectedID }) else { return apps }
        return [selected]
    }

    private func headroomColor(_ headroom: Headroom) -> Color {
        switch headroom {
        case .comfortable: return Palette.active
        case .moderate: return Palette.compressed
        case .low: return Color(red: 1.0, green: 0.38, blue: 0.39)
        }
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 22, height: 22)
                .background(Palette.surface)
                .clipShape(Circle())
                .overlay(Circle().stroke(Palette.border, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct MemoryCompositionBar: View {
    let snapshot: MemorySnapshot
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 3
            let usable = max(0, proxy.size.width - gap * 3)
            HStack(spacing: gap) {
                segment(width: usable * snapshot.ratio(snapshot.activeBytes), color: Palette.active)
                segment(width: usable * snapshot.ratio(snapshot.wiredBytes), color: Palette.wired)
                segment(width: usable * snapshot.ratio(snapshot.compressedBytes), color: Palette.compressed)
                segment(width: usable * snapshot.ratio(snapshot.availableBytes), color: Palette.available)
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(2, width))
    }
}

private struct CompactBucket: View {
    let color: Color
    let label: String
    let value: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .tracking(0.45)
                    .foregroundStyle(Palette.tertiary)
            }
            Text(ByteFormatter.compact(value))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MemoryDetail: View {
    let color: Color
    let title: String
    let value: UInt64
    let explanation: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.65)
                        .foregroundStyle(Palette.secondary)
                    Spacer(minLength: 4)
                    Text(ByteFormatter.compact(value))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                }
                Text(explanation)
                    .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MemoryHistoryChart: View {
    let points: [MemoryHistoryPoint]
    let contextPoints: [ContextHistoryPoint]
    let current: MemorySnapshot

    private var displayPoints: [MemoryHistoryPoint] {
        let now = Date().timeIntervalSince1970
        let cutoff = now - 60 * 60
        var result = points.filter { $0.timestamp >= cutoff }
        let live = MemoryHistoryPoint(timestamp: now, usedBytes: current.usedBytes, totalBytes: current.totalBytes)

        if let last = result.last, now - last.timestamp < 1 {
            result[result.count - 1] = live
        } else {
            result.append(live)
        }

        if result.count == 1 {
            result.insert(
                MemoryHistoryPoint(
                    timestamp: now - 1,
                    usedBytes: result[0].usedBytes,
                    totalBytes: result[0].totalBytes
                ),
                at: 0
            )
        }

        guard result.count > 360 else { return result }
        let stride = max(1, result.count / 360)
        var reduced = Swift.stride(from: 0, to: result.count, by: stride).map { result[$0] }
        if reduced.last?.timestamp != result.last?.timestamp, let last = result.last { reduced.append(last) }
        return reduced
    }

    var body: some View {
        let chartPoints = displayPoints
        let scale = usageScale(chartPoints)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.active)
                    .frame(width: 24, height: 24)
                    .background(Palette.active.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("MEMORY TREND")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(Palette.secondary)
                    Text(periodLabel(chartPoints))
                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .tracking(0.55)
                        .foregroundStyle(Palette.tertiary)
                }

                Spacer()

                Text("\(ByteFormatter.gigabytes(current.usedBytes)) GB")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()

                Text(changeLabel(chartPoints))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(changeColor(chartPoints))
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background(changeColor(chartPoints).opacity(0.09))
                    .clipShape(Capsule())
            }

            GeometryReader { proxy in
                let inset = EdgeInsets(top: 5, leading: 1, bottom: 4, trailing: 28)
                let plotSize = CGSize(
                    width: max(1, proxy.size.width - inset.leading - inset.trailing),
                    height: max(1, proxy.size.height - inset.top - inset.bottom)
                )
                let positions = pointPositions(chartPoints, size: plotSize, scale: scale)

                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { index in
                            Rectangle()
                                .fill(Palette.border.opacity(index == 3 ? 0.75 : 0.42))
                                .frame(height: 0.5)
                            if index < 3 { Spacer() }
                        }
                    }
                    .frame(width: plotSize.width, height: plotSize.height)
                    .offset(x: inset.leading, y: inset.top)

                    areaPath(positions, plotSize: plotSize, inset: inset)
                        .fill(
                            LinearGradient(
                                colors: [Palette.active.opacity(0.22), Palette.active.opacity(0.015)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    linePath(positions, inset: inset)
                        .stroke(
                            LinearGradient(
                                colors: [Palette.active.opacity(0.62), Palette.active, Color(red: 0.40, green: 0.67, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: Palette.active.opacity(0.28), radius: 3)

                    if let last = positions.last {
                        Circle()
                            .fill(Palette.ink)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Palette.active, lineWidth: 2))
                            .shadow(color: Palette.active.opacity(0.75), radius: 4)
                            .position(x: last.x + inset.leading, y: last.y + inset.top)
                    }

                    VStack(alignment: .trailing) {
                        Text("\(Int(scale.upperBound * 100))%")
                        Spacer()
                        Text("\(Int(scale.lowerBound * 100))%")
                    }
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.tertiary)
                    .frame(width: 25, height: plotSize.height)
                    .offset(x: plotSize.width + 4, y: inset.top)
                }
            }
            .frame(height: 60)

            HStack {
                Text(startLabel(displayPoints))
                Spacer()
                Text("NOW")
            }
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .tracking(0.55)
            .foregroundStyle(Palette.tertiary)

            ContextTimelineRibbon(points: contextPoints)
        }
        .padding(10)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Palette.border, lineWidth: 0.75))
        .help("Saved locally in Application Support. The chart shows the most recent hour.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory trend, \(ByteFormatter.gigabytes(current.usedBytes)) gigabytes used, \(changeLabel(chartPoints)) during \(periodLabel(chartPoints))")
    }

    private func usageScale(_ points: [MemoryHistoryPoint]) -> ClosedRange<Double> {
        let values = points.map(\.usage)
        let minimum = values.min() ?? current.usage
        let maximum = values.max() ?? current.usage
        let center = (minimum + maximum) / 2
        let span = max(0.10, maximum - minimum + 0.04)
        var lower = max(0, center - span / 2)
        var upper = min(1, center + span / 2)
        if upper - lower < span {
            if lower == 0 { upper = min(1, span) }
            if upper == 1 { lower = max(0, 1 - span) }
        }
        return lower...upper
    }

    private func pointPositions(
        _ points: [MemoryHistoryPoint],
        size: CGSize,
        scale: ClosedRange<Double>
    ) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        let duration = max(1, last.timestamp - first.timestamp)
        let verticalSpan = max(0.001, scale.upperBound - scale.lowerBound)
        return points.map { point in
            let x = size.width * CGFloat((point.timestamp - first.timestamp) / duration)
            let normalized = (point.usage - scale.lowerBound) / verticalSpan
            let y = size.height * CGFloat(1 - min(max(normalized, 0), 1))
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ positions: [CGPoint], inset: EdgeInsets) -> Path {
        var path = Path()
        guard let first = positions.first else { return path }
        path.move(to: CGPoint(x: first.x + inset.leading, y: first.y + inset.top))
        for point in positions.dropFirst() {
            path.addLine(to: CGPoint(x: point.x + inset.leading, y: point.y + inset.top))
        }
        return path
    }

    private func areaPath(_ positions: [CGPoint], plotSize: CGSize, inset: EdgeInsets) -> Path {
        var path = linePath(positions, inset: inset)
        guard let first = positions.first, let last = positions.last else { return path }
        path.addLine(to: CGPoint(x: last.x + inset.leading, y: plotSize.height + inset.top))
        path.addLine(to: CGPoint(x: first.x + inset.leading, y: plotSize.height + inset.top))
        path.closeSubpath()
        return path
    }

    private func periodLabel(_ points: [MemoryHistoryPoint]) -> String {
        guard let first = points.first, let last = points.last else { return "STARTING · SAVED" }
        let duration = last.timestamp - first.timestamp
        if duration >= 55 * 60 { return "LAST HOUR · SAVED" }
        if duration < 60 { return "SESSION · \(max(1, Int(duration))) SEC · SAVED" }
        return "SESSION · \(max(1, Int(duration / 60))) MIN · SAVED"
    }

    private func startLabel(_ points: [MemoryHistoryPoint]) -> String {
        guard let first = points.first, let last = points.last else { return "START" }
        let minutes = Int((last.timestamp - first.timestamp) / 60)
        if minutes >= 55 { return "1H AGO" }
        if minutes >= 1 { return "\(minutes)M AGO" }
        return "START"
    }

    private func changeLabel(_ points: [MemoryHistoryPoint]) -> String {
        guard let first = points.first else { return "±0 MB" }
        let difference = Int64(current.usedBytes) - Int64(first.usedBytes)
        let magnitude = ByteFormatter.compact(UInt64(abs(difference)))
        if abs(difference) < 10 * 1_048_576 { return "±0 MB" }
        return difference > 0 ? "+\(magnitude)" : "−\(magnitude)"
    }

    private func changeColor(_ points: [MemoryHistoryPoint]) -> Color {
        guard let first = points.first else { return Palette.secondary }
        let difference = Int64(current.usedBytes) - Int64(first.usedBytes)
        if abs(difference) < 10 * 1_048_576 { return Palette.secondary }
        return difference > 0 ? Palette.compressed : Palette.active
    }
}

private struct ContextObservatoryCard: View {
    @ObservedObject var observatory: ContextObservatory

    var body: some View {
        let snapshot = observatory.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.state.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(contextColor(snapshot.state))
                    .frame(width: 24, height: 24)
                    .background(contextColor(snapshot.state).opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("CONTEXT OBSERVATORY")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(Palette.secondary)
                    Text("LOCAL EVIDENCE · FIXED 30S AUDIO RING")
                        .font(.system(size: 7.2, weight: .bold, design: .rounded))
                        .tracking(0.42)
                        .foregroundStyle(Palette.tertiary)
                }

                Spacer()

                Circle()
                    .fill(observatory.isPressurePaused ? Palette.compressed : Palette.active)
                    .frame(width: 6, height: 6)
                Text(observatory.isPressurePaused ? "THROTTLED" : "OBSERVING")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .tracking(0.55)
                    .foregroundStyle(observatory.isPressurePaused ? Palette.compressed : Palette.active)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.state.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("\(Int(snapshot.confidence * 100))%")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(contextColor(snapshot.state))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(contextColor(snapshot.state).opacity(0.09))
                    .clipShape(Capsule())
                Spacer()
                Text(snapshot.signals.frontmostApp.uppercased())
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .tracking(0.45)
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }

            Text(snapshot.explanation)
                .font(.system(size: 9.3, weight: .regular, design: .rounded))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ContextSignalChip(symbol: "video.fill", label: "CAMERA", state: snapshot.signals.camera)
                ContextSignalChip(symbol: "mic.fill", label: "MIC", state: snapshot.signals.microphone)
                ContextSignalChip(
                    symbol: "rectangle.on.rectangle",
                    label: "SCREEN",
                    state: snapshot.signals.screen,
                    action: snapshot.signals.screen == .available ? nil : { observatory.requestScreenPermission() }
                )
                ContextSignalChip(symbol: "cursorarrow.motionlines", label: "INPUT", state: snapshot.signals.input)
                Spacer(minLength: 0)
            }

            if let evidence = snapshot.evidence.first {
                HStack(spacing: 6) {
                    Circle().fill(contextColor(snapshot.state)).frame(width: 4, height: 4)
                    Text(evidence)
                        .font(.system(size: 8.2, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [contextColor(snapshot.state).opacity(0.075), Palette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(contextColor(snapshot.state).opacity(0.24), lineWidth: 0.8))
        .help("Camera, microphone, screen, input, and memory evidence are analyzed locally. Raw media is automatically removed after seven days.")
    }
}

private struct CompactContextGlance: View {
    let snapshot: ContextSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.state.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(contextColor(snapshot.state))
            Text(snapshot.state.shortTitle)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .tracking(0.65)
                .foregroundStyle(Palette.ink)
            Circle().fill(Palette.tertiary).frame(width: 2.5, height: 2.5)
            Text(snapshot.signals.frontmostApp)
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            Spacer()
            Text("LOCAL")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(Palette.active)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(contextColor(snapshot.state).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ContextSignalChip: View {
    let symbol: String
    let label: String
    let state: ContextPermissionState
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { chipContent }
                    .buttonStyle(.plain)
                    .help("Silently verify existing Screen Recording access. Memory Widget never opens System Settings.")
            } else {
                chipContent
            }
        }
    }

    private var chipContent: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 7, weight: .semibold))
            Text(label).font(.system(size: 6.7, weight: .bold, design: .rounded)).tracking(0.35)
        }
        .foregroundStyle(signalColor)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(signalColor.opacity(0.08))
        .clipShape(Capsule())
    }

    private var signalColor: Color {
        switch state {
        case .available: return Palette.active
        case .pending: return Palette.secondary
        case .denied, .unavailable: return Palette.compressed
        }
    }
}

private struct ContextTimelineRibbon: View {
    let points: [ContextHistoryPoint]

    private var displayPoints: [ContextHistoryPoint] {
        let cutoff = Date().timeIntervalSince1970 - 60 * 60
        return Array(points.filter { $0.timestamp >= cutoff }.suffix(240))
    }

    var body: some View {
        let current = displayPoints
        Canvas { context, size in
            guard !current.isEmpty else {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.border.opacity(0.5)))
                return
            }
            let first = current.first!.timestamp
            let last = max(first + 1, current.last!.timestamp)
            for index in current.indices {
                let point = current[index]
                let nextTime = index < current.index(before: current.endIndex) ? current[current.index(after: index)].timestamp : last
                let x = size.width * CGFloat((point.timestamp - first) / (last - first))
                let nextX = size.width * CGFloat((nextTime - first) / (last - first))
                let rect = CGRect(x: x, y: 0, width: max(2, nextX - x + 1), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(contextColor(point.state).opacity(0.78)))
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
        .accessibilityLabel("Context state timeline synchronized with the memory chart")
    }
}

private func contextColor(_ state: ContextState) -> Color {
    switch state {
    case .observing: return Palette.secondary
    case .engaged: return Palette.active
    case .watching: return Color(red: 0.39, green: 0.68, blue: 1.0)
    case .roomActive: return Color(red: 0.73, green: 0.53, blue: 1.0)
    case .autonomous: return Palette.compressed
    case .away: return Color(red: 0.39, green: 0.45, blue: 0.58)
    }
}

private struct AppFootprintRow: View {
    let app: AppFootprint
    let rank: Int
    let maximumBytes: UInt64
    let isExpanded: Bool
    let isCondensed: Bool
    let onToggle: () -> Void

    private var isPlaceholder: Bool { app.processCount == 0 }

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: isExpanded ? 10 : 7) {
                HStack(alignment: .center, spacing: 9) {
                    ZStack(alignment: .bottomTrailing) {
                        AppIdentityIcon(app: app, size: isExpanded ? 34 : 26)
                        if !isPlaceholder {
                            Text("\(rank)")
                                .font(.system(size: 7, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.panel)
                                .frame(width: 13, height: 13)
                                .background(Palette.active)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Palette.panel, lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.system(size: isExpanded ? 14 : 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(isPlaceholder ? Palette.tertiary : Palette.ink)
                            .lineLimit(1)

                        if isExpanded {
                            Text(expandedDetailLine)
                                .font(.system(size: 9, weight: .regular, design: .rounded))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if !isPlaceholder {
                        Text(ByteFormatter.compact(app.bytes))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.ink)
                            .monospacedDigit()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(isExpanded ? Palette.active : Palette.tertiary)
                            .frame(width: 12)
                    }
                }

                if !isCondensed && !isExpanded {
                    Text(detailLine)
                        .font(.system(size: 9.5, weight: .regular, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .padding(.leading, 35)

                    footprintBar
                }

                if isExpanded {
                    footprintBar

                    ProvenanceCard(app: app)
                }
            }
            .padding(isExpanded ? 11 : 0)
            .background(isExpanded ? Palette.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isExpanded ? Palette.active.opacity(0.22) : Color.clear, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPlaceholder)
        .help(isPlaceholder ? "Measuring app footprints" : (isExpanded ? "Collapse \(app.name)" : "Explain \(app.name)'s memory"))
        .accessibilityLabel(isPlaceholder ? "Measuring app footprints" : "\(app.name), \(ByteFormatter.compact(app.bytes))")
        .accessibilityHint(isExpanded ? "Collapse process details" : "Expand process details")
    }

    private var footprintBar: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(isPlaceholder ? Palette.surface : Palette.active.opacity(0.60))
                .frame(width: barWidth(proxy.size.width))
        }
        .frame(height: 3)
    }

    private var detailLine: String {
        guard !isPlaceholder else { return app.explanation }
        let processWord = app.processCount == 1 ? "process" : "processes"
        return "\(app.processCount) \(processWord)  ·  \(app.explanation)"
    }

    private var expandedDetailLine: String {
        let processWord = app.processCount == 1 ? "process" : "processes"
        return "\(app.processCount) \(processWord) · source traced below"
    }

    private func barWidth(_ available: CGFloat) -> CGFloat {
        guard !isPlaceholder, maximumBytes > 0 else { return available * 0.24 }
        return max(4, available * min(1, Double(app.bytes) / Double(maximumBytes)))
    }
}

private struct ProvenanceCard: View {
    let app: AppFootprint

    private var meaningfulRoles: [ProcessRoleFootprint] {
        if app.roles.count == 1, app.roles.first?.role == .other { return [] }
        return app.roles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(app.provenance.plainLanguage)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            provenanceChain

            Divider().overlay(Palette.border)

            VStack(alignment: .leading, spacing: 4) {
                Text("WHY IT EXISTS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Palette.active)
                Text(app.provenance.whyItExists)
                    .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.active)
                Text(runtimeLabel)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                Circle().fill(Palette.tertiary).frame(width: 2.5, height: 2.5)
                Text("ACTIVE NOW")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.45)
                    .foregroundStyle(Palette.active)
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Text("Hover sources to see the evidence")
                    .font(.system(size: 7.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.tertiary)
                Spacer(minLength: 4)
                confidenceCapsule
            }

            if !meaningfulRoles.isEmpty {
                Divider().overlay(Palette.border)

                VStack(alignment: .leading, spacing: 7) {
                    Text("MEMORY INSIDE")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(Palette.tertiary)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                        ForEach(meaningfulRoles) { role in
                            CompactProcessRole(role: role)
                        }
                    }
                }
            }
        }
        .padding(11)
        .background(Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Palette.border, lineWidth: 0.75))
    }

    private var provenanceChain: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(Array(app.provenance.nodes.enumerated()), id: \.element.id) { index, node in
                ProvenanceNodeView(node: node)
                if index < app.provenance.nodes.count - 1 {
                    VStack {
                        Spacer().frame(height: 18)
                        Rectangle()
                            .fill(Palette.active.opacity(0.55))
                            .frame(height: 1.5)
                            .shadow(color: Palette.active.opacity(0.45), radius: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var confidenceCapsule: some View {
        HStack(spacing: 5) {
            Image(systemName: app.provenance.confidence.symbol)
                .font(.system(size: 7.5, weight: .bold))
            Text(app.provenance.confidence.rawValue)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.55)
        }
        .foregroundStyle(confidenceColor)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(confidenceColor.opacity(0.09))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(confidenceColor.opacity(0.24), lineWidth: 0.75))
        .help(app.provenance.evidence)
    }

    private var confidenceColor: Color {
        switch app.provenance.confidence {
        case .confirmed, .system: return Palette.active
        case .inferred: return Palette.compressed
        case .unknown: return Palette.secondary
        }
    }

    private var runtimeLabel: String {
        guard let seconds = app.provenance.runningSeconds else { return "Start time unavailable" }
        return "Started \(DurationFormatter.compact(seconds)) ago"
    }
}

private struct ProvenanceNodeView: View {
    let node: ProvenanceNode

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let path = node.appPath {
                    Image(nsImage: AppIconCache.shared.image(path: path, name: node.title, fallbackSymbol: node.symbol))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: node.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            .frame(width: 36, height: 36)
            .background(Palette.active.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.active.opacity(0.42), lineWidth: 0.8))

            Text(node.title)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 78)
        }
        .help(node.detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.title)
        .accessibilityHint(node.detail)
    }
}

private struct CompactProcessRole: View {
    let role: ProcessRoleFootprint

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: role.role.symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Palette.active)
                .frame(width: 20, height: 20)
                .background(Palette.active.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(role.role.title)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                Text(ByteFormatter.compact(role.bytes))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("\(role.processCount == 1 ? "1 process" : "\(role.processCount) processes") · \(role.role.explanation)")
    }
}

private struct AppIdentityIcon: View {
    let app: AppFootprint
    let size: CGFloat

    var body: some View {
        Image(nsImage: AppIconCache.shared.image(for: app))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .opacity(app.processCount == 0 ? 0.35 : 1)
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for app: AppFootprint) -> NSImage {
        image(path: app.appPath, name: app.name, fallbackSymbol: fallbackSymbol(for: app.name))
    }

    func image(path: String?, name: String, fallbackSymbol: String) -> NSImage {
        let key = (path ?? "symbol:\(name):\(fallbackSymbol)") as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image: NSImage
        if let path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(
                systemSymbolName: fallbackSymbol,
                accessibilityDescription: name
            ) ?? NSImage(size: NSSize(width: 32, height: 32))
        }
        cache.setObject(image, forKey: key)
        return image
    }

    private func fallbackSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("windowserver") { return "rectangle.3.group.fill" }
        if lower.contains("finder") { return "folder.fill" }
        if lower.contains("quick look") { return "eye.fill" }
        if lower.contains("open & save") { return "folder.badge.gearshape" }
        if lower.contains("virtual") || lower.contains("docker") { return "shippingbox.fill" }
        if lower.contains("kernel") || lower.contains("system") { return "memorychip.fill" }
        return "app.dashed"
    }
}

private struct MenuBarMemoryView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var observatory: ContextObservatory
    @ObservedObject var presentation: WidgetPresentation
    @ObservedObject var menuPresentation: MenuBarPresentation
    let onShowFull: () -> Void
    let onShowCompact: () -> Void
    let onQuit: () -> Void
    let onContentSizeChange: (CGSize) -> Void

    var body: some View {
        let snapshot = monitor.snapshot
        let selectedApp = snapshot.apps.first { $0.id == menuPresentation.selectedFootprintID }

        VStack(alignment: .leading, spacing: 16) {
            menuSummary(snapshot)

            CompactContextGlance(snapshot: observatory.snapshot)

            Divider().overlay(Palette.border)

            Group {
                if let selectedApp {
                    MenuFootprintDetail(
                        app: selectedApp,
                        rank: (snapshot.apps.firstIndex { $0.id == selectedApp.id } ?? 0) + 1
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            menuPresentation.selectedFootprintID = nil
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                } else {
                    MenuFootprintList(apps: snapshot.apps) { app in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            menuPresentation.selectedFootprintID = app.id
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: menuPresentation.selectedFootprintID)

            Divider().overlay(Palette.border)

            HStack(spacing: 8) {
                MenuModeButton(title: "FULL", symbol: "rectangle.expand.vertical", isSelected: !presentation.isCollapsed, action: onShowFull)
                MenuModeButton(title: "COMPACT", symbol: "rectangle.compress.vertical", isSelected: presentation.isCollapsed, action: onShowCompact)
                Spacer(minLength: 4)
                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 30, height: 30)
                        .background(Palette.surface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Quit Memory Widget")
                .accessibilityLabel("Quit Memory Widget")
            }
        }
        .padding(18)
        .frame(width: 356, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: true)
        .background(Palette.panel)
        .preferredColorScheme(.dark)
        .reportContentSize(onContentSizeChange)
    }

    private func menuSummary(_ snapshot: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Circle().fill(Palette.active).frame(width: 7, height: 7)
                Text("MEMORY")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(snapshot.headroom.rawValue)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(headroomColor(snapshot.headroom))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(headroomColor(snapshot.headroom).opacity(0.10))
                    .clipShape(Capsule())
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(Palette.active)
            }

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ByteFormatter.gigabytes(snapshot.usedBytes)) GB")
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                    Text("USED  ·  \(Int(snapshot.usage * 100))% OF \(ByteFormatter.gigabytes(snapshot.totalBytes)) GB")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.55)
                        .foregroundStyle(Palette.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(ByteFormatter.gigabytes(snapshot.availableBytes)) GB")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.active)
                        .monospacedDigit()
                    Text("AVAILABLE")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.65)
                        .foregroundStyle(Palette.secondary)
                }
            }

            MemoryCompositionBar(snapshot: snapshot, height: 8)

            HStack(spacing: 0) {
                CompactBucket(color: Palette.active, label: "ACTIVE", value: snapshot.activeBytes)
                CompactBucket(color: Palette.wired, label: "SYSTEM", value: snapshot.wiredBytes)
                CompactBucket(color: Palette.compressed, label: "PACKED", value: snapshot.compressedBytes)
                CompactBucket(color: Palette.available, label: "FREE", value: snapshot.availableBytes)
            }
        }
    }

    private func headroomColor(_ headroom: Headroom) -> Color {
        switch headroom {
        case .comfortable: return Palette.active
        case .moderate: return Palette.compressed
        case .low: return Color(red: 1.0, green: 0.38, blue: 0.39)
        }
    }
}

private struct MenuFootprintList: View {
    let apps: [AppFootprint]
    let onSelect: (AppFootprint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("LARGEST APP FOOTPRINTS")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Palette.secondary)
                Spacer()
                Text("TAP TO EXPLAIN")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .tracking(0.65)
                    .foregroundStyle(Palette.active)
            }

            ForEach(Array(paddedApps(apps, count: 3).enumerated()), id: \.element.id) { index, app in
                MenuAppRow(app: app, rank: index + 1) {
                    onSelect(app)
                }
            }
        }
    }
}

private struct MenuAppRow: View {
    let app: AppFootprint
    let rank: Int
    let onSelect: () -> Void

    private var isPlaceholder: Bool { app.processCount == 0 }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        AppIdentityIcon(app: app, size: 23)
                        if !isPlaceholder {
                            Text("\(rank)")
                                .font(.system(size: 6.5, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.panel)
                                .frame(width: 11, height: 11)
                                .background(Palette.active)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Palette.panel, lineWidth: 1))
                                .offset(x: 2, y: 2)
                        }
                    }
                    Text(app.name)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isPlaceholder ? Palette.tertiary : Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if !isPlaceholder {
                        Text(ByteFormatter.compact(app.bytes))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.ink)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Palette.tertiary)
                            .frame(width: 9)
                    }
                }
                Text(detailLine)
                    .font(.system(size: 8.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 31)
            }
        }
        .buttonStyle(.plain)
        .disabled(isPlaceholder)
        .accessibilityLabel(isPlaceholder ? "Measuring app footprint" : "Explain \(app.name), \(ByteFormatter.compact(app.bytes))")
    }

    private var detailLine: String {
        guard !isPlaceholder else { return app.explanation }
        let processWord = app.processCount == 1 ? "process" : "processes"
        return "\(app.processCount) \(processWord)  ·  \(app.explanation)"
    }
}

private struct MenuFootprintDetail: View {
    let app: AppFootprint
    let rank: Int
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Palette.active)
                        .frame(width: 24, height: 24)
                        .background(Palette.active.opacity(0.09))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back to largest footprints")
                .accessibilityLabel("Back to largest footprints")

                Text("FOOTPRINT EXPLAINED")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Palette.secondary)

                Spacer()

                Text("BACK")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .tracking(0.65)
                    .foregroundStyle(Palette.active)
            }

            HStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    AppIdentityIcon(app: app, size: 31)
                    Text("\(rank)")
                        .font(.system(size: 6.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.panel)
                        .frame(width: 12, height: 12)
                        .background(Palette.active)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Palette.panel, lineWidth: 1))
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text("\(app.processCount == 1 ? "1 process" : "\(app.processCount) processes") · live source trace")
                        .font(.system(size: 8.5, weight: .regular, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                }

                Spacer(minLength: 6)

                Text(ByteFormatter.compact(app.bytes))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
            }

            ProvenanceCard(app: app)
        }
    }
}

private struct MenuModeButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.55)
            }
            .foregroundStyle(isSelected ? Palette.active : Palette.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isSelected ? Palette.active.opacity(0.10) : Palette.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isSelected ? Palette.active.opacity(0.28) : Palette.border, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(title.lowercased()) desktop widget")
    }
}

private func paddedApps(_ apps: [AppFootprint], count: Int) -> [AppFootprint] {
    var result = Array(apps.prefix(count))
    while result.count < count {
        result.append(.placeholder(result.count))
    }
    return result
}

// MARK: - Content-driven window sizing

private struct ContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

private extension View {
    func reportContentSize(_ callback: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentSizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ContentSizePreferenceKey.self) { size in
            DispatchQueue.main.async { callback(size) }
        }
    }
}

enum ByteFormatter {
    static func gigabytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0.0" }
        return String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    static func compact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

}

enum DurationFormatter {
    static func compact(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(1, minutes))m"
    }
}

// MARK: - App lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private let monitor = MemoryMonitor()
    private lazy var observatory = ContextObservatory(monitor: monitor)
    private let presentation = WidgetPresentation()
    private let menuPresentation = MenuBarPresentation()
    private var window: NSWindow!
    private var hostingView: NSHostingView<MemoryWidgetView>!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var statusRefreshTimer: Timer?
    private var hostingGeneration = UUID()
    private var lastContentSize = CGSize.zero
    private var hasPlacedWindow = false
    private var isFittingWindow = false
    private var lastPopoverSize = CGSize.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBarOnly = UserDefaults.standard.bool(forKey: "menuBarOnly")
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        setupMenuBar()
        setupWindow()

        if menuBarOnly {
            window.orderOut(nil)
            window.alphaValue = 1
        } else {
            window.makeKeyAndOrderFront(nil)
            window.alphaValue = 1
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDesktopWidget(collapsed: nil)
        return true
    }

    // Menu-bar-only mode intentionally has no visible desktop window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        statusRefreshTimer?.invalidate()
        observatory.stop()
        monitor.persistHistory()
        MCPStateStore.markStopped()
        if statusItem != nil { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    func windowDidMove(_ notification: Notification) {
        guard hasPlacedWindow, !isFittingWindow else { return }
        UserDefaults.standard.set(window.frame.origin.x, forKey: "windowOriginX")
        UserDefaults.standard.set(window.frame.origin.y, forKey: "windowOriginY")
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.title = "Memory"
        window.alphaValue = 0

        installWidgetContent()
    }

    private func installWidgetContent() {
        let generation = UUID()
        hostingGeneration = generation
        let root = MemoryWidgetView(
            monitor: monitor,
            observatory: observatory,
            presentation: presentation,
            onToggleCollapsed: { [weak self] in self?.toggleDesktopCollapsed() },
            onEnterMenuBarMode: { [weak self] in self?.enterMenuBarMode() },
            onContentSizeChange: { [weak self] size in
                guard self?.hostingGeneration == generation else { return }
                self?.fitWindow(to: size)
            }
        )
        let newHostingView = NSHostingView(rootView: root)
        newHostingView.sizingOptions = [.intrinsicContentSize, .minSize]
        hostingView = newHostingView
        window.contentView = newHostingView

        lastContentSize = .zero
        newHostingView.layoutSubtreeIfNeeded()
        fitWindow(to: newHostingView.fittingSize)
    }

    private func toggleDesktopCollapsed() {
        let wasVisible = window.isVisible
        if wasVisible { window.alphaValue = 0 }
        presentation.isCollapsed.toggle()
        installWidgetContent()
        if wasVisible {
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Memory")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            button.target = self
            button.action = #selector(toggleMenuBarPopover)
        }

        let menuView = MenuBarMemoryView(
            monitor: monitor,
            observatory: observatory,
            presentation: presentation,
            menuPresentation: menuPresentation,
            onShowFull: { [weak self] in self?.showDesktopWidget(collapsed: false) },
            onShowCompact: { [weak self] in self?.showDesktopWidget(collapsed: true) },
            onQuit: { NSApp.terminate(nil) },
            onContentSizeChange: { [weak self] size in self?.fitPopover(to: size) }
        )
        let controller = NSHostingController(rootView: menuView)
        controller.sizingOptions = [.preferredContentSize]
        controller.view.layoutSubtreeIfNeeded()
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        updateStatusItem()
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
            }
        }
    }

    @objc private func toggleMenuBarPopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showMenuBarPopover()
        }
    }

    private func showMenuBarPopover() {
        guard let button = statusItem.button else { return }
        menuPresentation.reset()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fitPopover(to size: CGSize) {
        guard size.width > 0,
              size.height > 0,
              abs(size.width - lastPopoverSize.width) > 0.5 || abs(size.height - lastPopoverSize.height) > 0.5 else { return }

        lastPopoverSize = size
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
    }

    private func updateStatusItem() {
        let snapshot = monitor.snapshot
        statusItem.button?.title = "\(ByteFormatter.gigabytes(snapshot.usedBytes))G"
        statusItem.button?.toolTip = "Memory: \(ByteFormatter.gigabytes(snapshot.usedBytes)) GB used, \(ByteFormatter.gigabytes(snapshot.availableBytes)) GB available · \(observatory.snapshot.state.title.capitalized)"
    }

    private func enterMenuBarMode() {
        UserDefaults.standard.set(true, forKey: "menuBarOnly")
        showMenuBarPopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self,
                  UserDefaults.standard.bool(forKey: "menuBarOnly") else { return }
            self.window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "menuBarOnly") {
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showDesktopWidget(collapsed: Bool?) {
        if let collapsed { presentation.isCollapsed = collapsed }
        UserDefaults.standard.set(false, forKey: "menuBarOnly")
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        window.alphaValue = 0
        installWidgetContent()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fitWindow(to contentSize: CGSize) {
        guard window != nil,
              contentSize.width > 0,
              contentSize.height > 0,
              abs(contentSize.width - lastContentSize.width) > 0.5 || abs(contentSize.height - lastContentSize.height) > 0.5 else { return }

        isFittingWindow = true
        defer { isFittingWindow = false }

        let oldTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        let newFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let newOrigin = NSPoint(x: oldTopLeft.x, y: oldTopLeft.y - newFrameSize.height)
        window.setFrame(NSRect(origin: newOrigin, size: newFrameSize), display: true)
        lastContentSize = contentSize

        if !hasPlacedWindow {
            restorePositionOrCenter()
            hasPlacedWindow = true
        }
    }

    private func restorePositionOrCenter() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "windowOriginX") != nil,
           defaults.object(forKey: "windowOriginY") != nil {
            let origin = NSPoint(
                x: defaults.double(forKey: "windowOriginX"),
                y: defaults.double(forKey: "windowOriginY")
            )
            let candidate = NSRect(origin: origin, size: window.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                window.setFrameOrigin(origin)
                return
            }
        }
        window.center()
    }
}

@main
enum MemoryWidgetMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
