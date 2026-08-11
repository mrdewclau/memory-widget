import Foundation

enum MCPStateStore {
    private static var stateURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("Memory Widget", isDirectory: true)
            .appendingPathComponent("mcp-live-state.json", isDirectory: false)
    }

    static func publish(memory: MemorySnapshot, context: ContextSnapshot) {
        let footprints: [[String: Any]] = memory.apps.map { app in
            [
                "id": app.id,
                "name": app.name,
                "appPath": app.appPath.map { $0 as Any } ?? NSNull(),
                "bytes": app.bytes,
                "processCount": app.processCount,
                "explanation": app.explanation,
                "roles": app.roles.map { role in
                    [
                        "role": role.role.rawValue,
                        "title": role.role.title,
                        "explanation": role.role.explanation,
                        "bytes": role.bytes,
                        "processCount": role.processCount
                    ] as [String: Any]
                },
                "provenance": [
                    "plainLanguage": app.provenance.plainLanguage,
                    "whyItExists": app.provenance.whyItExists,
                    "confidence": app.provenance.confidence.rawValue,
                    "evidence": app.provenance.evidence,
                    "runningSeconds": app.provenance.runningSeconds.map { $0 as Any } ?? NSNull(),
                    "nodes": app.provenance.nodes.map { node in
                        [
                            "id": node.id,
                            "title": node.title,
                            "appPath": node.appPath.map { $0 as Any } ?? NSNull(),
                            "symbol": node.symbol,
                            "detail": node.detail
                        ] as [String: Any]
                    }
                ] as [String: Any]
            ] as [String: Any]
        }

        let signals = context.signals
        let document: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "generatedAtUnix": Date().timeIntervalSince1970,
            "app": [
                "name": "Memory Widget",
                "bundleIdentifier": "local.memory-widget",
                "version": "2.1",
                "running": true,
                "processID": ProcessInfo.processInfo.processIdentifier
            ] as [String: Any],
            "memory": [
                "totalBytes": memory.totalBytes,
                "usedBytes": memory.usedBytes,
                "availableBytes": memory.availableBytes,
                "activeBytes": memory.activeBytes,
                "wiredBytes": memory.wiredBytes,
                "compressedBytes": memory.compressedBytes,
                "usedRatio": memory.usage,
                "availableRatio": memory.availableRatio,
                "headroom": memory.headroom.rawValue,
                "footprints": footprints
            ] as [String: Any],
            "context": [
                "state": context.state.rawValue,
                "title": context.state.title,
                "confidence": context.confidence,
                "explanation": context.explanation,
                "evidence": context.evidence,
                "lastObservedAt": ISO8601DateFormatter().string(from: context.lastObservedAt),
                "signals": [
                    "camera": signals.camera.rawValue,
                    "microphone": signals.microphone.rawValue,
                    "screen": signals.screen.rawValue,
                    "input": signals.input.rawValue,
                    "humanSeen": signals.humanSeen,
                    "animalSeen": signals.animalSeen,
                    "animalKind": signals.animalKind.map { $0 as Any } ?? NSNull(),
                    "dominantSound": signals.dominantSound.map { $0 as Any } ?? NSNull(),
                    "soundConfidence": signals.soundConfidence,
                    "audioApps": signals.audioApps,
                    "cpuPercent": signals.cpuPercent,
                    "screenSummary": signals.screenSummary.map { $0 as Any } ?? NSNull(),
                    "frontmostApp": signals.frontmostApp,
                    "idleSeconds": signals.idleSeconds
                ] as [String: Any]
            ] as [String: Any]
        ]

        write(document)
    }

    static func markStopped() {
        guard let data = try? Data(contentsOf: stateURL),
              var document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var app = document["app"] as? [String: Any] else { return }
        app["running"] = false
        document["app"] = app
        document["generatedAt"] = ISO8601DateFormatter().string(from: Date())
        document["generatedAtUnix"] = Date().timeIntervalSince1970
        write(document)
    }

    private static func write(_ document: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stateURL, options: .atomic)
        } catch {
            return
        }
    }
}
