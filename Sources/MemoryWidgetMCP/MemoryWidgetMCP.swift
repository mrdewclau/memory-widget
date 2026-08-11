import Foundation

@main
enum MemoryWidgetMCPServer {
    private static let modernVersion = "2026-07-28"
    private static let legacyVersion = "2025-11-25"
    private static let serverInfo: [String: Any] = [
        "name": "memory-widget",
        "title": "Memory Widget",
        "version": "2.1.0",
        "description": "Local, read-only access to this Mac's Memory Widget telemetry"
    ]

    private static var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Memory Widget", isDirectory: true)
    }

    private static var appURL: URL {
        if let configured = ProcessInfo.processInfo.environment["MEMORY_WIDGET_APP_PATH"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func main() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                writeError(id: NSNull(), code: -32700, message: "Parse error")
                continue
            }
            handle(request)
        }
    }

    private static func handle(_ request: [String: Any]) {
        let method = request["method"] as? String ?? ""
        let id = request["id"] ?? NSNull()
        let isNotification = request["id"] == nil
        let modern = method == "server/discover" || requestedVersion(in: request) == modernVersion

        if let version = requestedVersion(in: request), version != modernVersion, version != legacyVersion {
            if !isNotification {
                writeError(id: id, code: -32020, message: "Unsupported MCP protocol version: \(version)")
            }
            return
        }

        switch method {
        case "server/discover":
            let result: [String: Any] = [
                "supportedVersions": [modernVersion, legacyVersion],
                "capabilities": ["tools": [:], "resources": [:]],
                "instructions": "Use this local server to inspect current RAM composition, app footprints, saved memory history, and the Context Observatory. Data never leaves this Mac. Call open_memory_widget only when the user needs the visual widget onscreen.",
                "ttlMs": 300_000,
                "cacheScope": "private"
            ]
            writeResult(id: id, result: result, modern: true)

        case "initialize":
            let result: [String: Any] = [
                // The July 2026 protocol does not use initialize. Any client
                // taking this route is intentionally negotiated to legacy MCP.
                "protocolVersion": legacyVersion,
                "capabilities": ["tools": [:], "resources": [:]],
                "serverInfo": serverInfo,
                "instructions": "Read-only local RAM telemetry from Memory Widget."
            ]
            writeResult(id: id, result: result, modern: false)

        case "notifications/initialized", "notifications/cancelled":
            return

        case "ping":
            writeResult(id: id, result: [:], modern: modern)

        case "tools/list":
            let result: [String: Any] = [
                "tools": tools,
                "ttlMs": 300_000,
                "cacheScope": "private"
            ]
            writeResult(id: id, result: result, modern: modern)

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let payload = callTool(name: name, arguments: arguments) else {
                writeError(id: id, code: -32602, message: "Unknown tool: \(name)")
                return
            }
            let result: [String: Any] = [
                "content": [["type": "text", "text": prettyJSON(payload.value)]],
                "structuredContent": payload.value,
                "isError": payload.isError
            ]
            writeResult(id: id, result: result, modern: modern)

        case "resources/list":
            let result: [String: Any] = [
                "resources": resources,
                "ttlMs": 300_000,
                "cacheScope": "private"
            ]
            writeResult(id: id, result: result, modern: modern)

        case "resources/templates/list":
            let result: [String: Any] = [
                "resourceTemplates": [],
                "ttlMs": 300_000,
                "cacheScope": "private"
            ]
            writeResult(id: id, result: result, modern: modern)

        case "resources/read":
            let params = request["params"] as? [String: Any] ?? [:]
            let uri = params["uri"] as? String ?? ""
            guard let payload = resourcePayload(uri: uri) else {
                writeError(id: id, code: -32602, message: "Unknown resource URI: \(uri)")
                return
            }
            let result: [String: Any] = [
                "contents": [["uri": uri, "mimeType": "application/json", "text": prettyJSON(payload)]],
                "ttlMs": uri == "memory-widget://live" ? 2_000 : 10_000,
                "cacheScope": "private"
            ]
            writeResult(id: id, result: result, modern: modern)

        default:
            if !isNotification {
                writeError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private static var tools: [[String: Any]] {
        let emptySchema: [String: Any] = ["type": "object", "additionalProperties": false]
        let readOnly: [String: Any] = [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false
        ]
        return [
            [
                "name": "get_memory_snapshot",
                "title": "Current Mac Memory",
                "description": "Get the complete current physical-RAM picture from Memory Widget: used, available, active, wired/system, compressed, headroom, and freshness.",
                "inputSchema": emptySchema,
                "annotations": readOnly
            ],
            [
                "name": "get_memory_footprints",
                "title": "Largest App Memory Footprints",
                "description": "Get app-grouped RAM footprints with process roles, source chain, purpose, evidence, and confidence.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "minimum": 1, "maximum": 20, "default": 5]
                    ],
                    "additionalProperties": false
                ],
                "annotations": readOnly
            ],
            [
                "name": "get_memory_history",
                "title": "Saved RAM History",
                "description": "Read Memory Widget's locally saved RAM timeline for a requested window, downsampled to a bounded number of points.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "minimum": 1, "maximum": 1440, "default": 60],
                        "maxPoints": ["type": "integer", "minimum": 10, "maximum": 500, "default": 120]
                    ],
                    "additionalProperties": false
                ],
                "annotations": readOnly
            ],
            [
                "name": "get_memory_context",
                "title": "Memory Context Observatory",
                "description": "Get the current local explanation of what the user, room, and Mac are doing alongside recent context-state changes.",
                "inputSchema": emptySchema,
                "annotations": readOnly
            ],
            [
                "name": "open_memory_widget",
                "title": "Open Memory Widget",
                "description": "Bring the visual Memory Widget to the screen. This does not change RAM, processes, permissions, or collected data.",
                "inputSchema": emptySchema,
                "annotations": [
                    "readOnlyHint": false,
                    "destructiveHint": false,
                    "idempotentHint": true,
                    "openWorldHint": false
                ]
            ]
        ]
    }

    private static var resources: [[String: Any]] {
        [
            [
                "uri": "memory-widget://live",
                "name": "memory-widget-live",
                "title": "Memory Widget Live State",
                "description": "Current RAM, footprints, and Context Observatory state.",
                "mimeType": "application/json"
            ],
            [
                "uri": "memory-widget://history/ram",
                "name": "memory-widget-ram-history",
                "title": "Memory Widget RAM History",
                "description": "Saved rolling 24-hour RAM timeline.",
                "mimeType": "application/json"
            ],
            [
                "uri": "memory-widget://history/context",
                "name": "memory-widget-context-history",
                "title": "Memory Widget Context History",
                "description": "Recent locally derived context states synchronized with RAM.",
                "mimeType": "application/json"
            ]
        ]
    }

    private static func callTool(name: String, arguments: [String: Any]) -> (value: Any, isError: Bool)? {
        switch name {
        case "get_memory_snapshot":
            guard let state = liveState() else { return (unavailablePayload(), true) }
            let memory = state["memory"] as? [String: Any] ?? [:]
            var result = memory
            result.removeValue(forKey: "footprints")
            result["source"] = state["source"]
            result["generatedAt"] = state["generatedAt"]
            result["freshnessSeconds"] = state["freshnessSeconds"]
            return (result, false)

        case "get_memory_footprints":
            guard let state = liveState() else { return (unavailablePayload(), true) }
            let memory = state["memory"] as? [String: Any] ?? [:]
            let all = memory["footprints"] as? [[String: Any]] ?? []
            let limit = boundedInt(arguments["limit"], defaultValue: 5, minimum: 1, maximum: 20)
            return ([
                "generatedAt": state["generatedAt"] ?? NSNull(),
                "freshnessSeconds": state["freshnessSeconds"] ?? NSNull(),
                "totalBytes": memory["totalBytes"] ?? 0,
                "usedBytes": memory["usedBytes"] ?? 0,
                "footprints": Array(all.prefix(limit))
            ], false)

        case "get_memory_history":
            let minutes = boundedInt(arguments["minutes"], defaultValue: 60, minimum: 1, maximum: 1440)
            let maxPoints = boundedInt(arguments["maxPoints"], defaultValue: 120, minimum: 10, maximum: 500)
            return (memoryHistory(minutes: minutes, maxPoints: maxPoints), false)

        case "get_memory_context":
            guard let state = liveState() else { return (unavailablePayload(), true) }
            return ([
                "generatedAt": state["generatedAt"] ?? NSNull(),
                "freshnessSeconds": state["freshnessSeconds"] ?? NSNull(),
                "context": state["context"] ?? [:],
                "recentTimeline": contextHistory(limit: 120)
            ], false)

        case "open_memory_widget":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [appURL.path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return (["opened": true, "appPath": appURL.path], false)
                }
                return (["opened": false, "error": "The macOS open command failed."], true)
            } catch {
                return (["opened": false, "error": error.localizedDescription], true)
            }

        default:
            return nil
        }
    }

    private static func resourcePayload(uri: String) -> Any? {
        switch uri {
        case "memory-widget://live": return liveState() ?? unavailablePayload()
        case "memory-widget://history/ram": return memoryHistory(minutes: 1440, maxPoints: 500)
        case "memory-widget://history/context": return contextHistory(limit: 480)
        default: return nil
        }
    }

    private static func liveState() -> [String: Any]? {
        let url = supportURL.appendingPathComponent("mcp-live-state.json")
        guard let data = try? Data(contentsOf: url),
              var state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let generated = state["generatedAtUnix"] as? Double ?? 0
        let freshness = max(0, Date().timeIntervalSince1970 - generated)
        state["freshnessSeconds"] = freshness
        state["source"] = "Memory Widget local app"
        state["live"] = freshness <= 15 && ((state["app"] as? [String: Any])?["running"] as? Bool == true)
        return state
    }

    private static func memoryHistory(minutes: Int, maxPoints: Int) -> [String: Any] {
        let url = supportURL.appendingPathComponent("memory-history.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ["windowMinutes": minutes, "points": [], "available": false]
        }
        let cutoff = Date().timeIntervalSince1970 - Double(minutes * 60)
        let filtered = decoded.filter { ($0["timestamp"] as? Double ?? 0) >= cutoff }
        let points = downsample(filtered, maximum: maxPoints)
        return [
            "windowMinutes": minutes,
            "pointCount": points.count,
            "available": true,
            "points": points
        ]
    }

    private static func contextHistory(limit: Int) -> [[String: Any]] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dates = [Date().addingTimeInterval(-86_400), Date()]
        var points: [[String: Any]] = []
        for date in dates {
            let url = supportURL
                .appendingPathComponent("Context Observatory", isDirectory: true)
                .appendingPathComponent("context-\(formatter.string(from: date)).jsonl")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let point = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                points.append(point)
            }
        }
        return Array(points.sorted { ($0["timestamp"] as? Double ?? 0) < ($1["timestamp"] as? Double ?? 0) }.suffix(limit))
    }

    private static func downsample(_ points: [[String: Any]], maximum: Int) -> [[String: Any]] {
        guard points.count > maximum else { return points }
        let stride = Double(points.count - 1) / Double(maximum - 1)
        return (0..<maximum).map { points[min(points.count - 1, Int((Double($0) * stride).rounded()))] }
    }

    private static func unavailablePayload() -> [String: Any] {
        [
            "available": false,
            "reason": "Memory Widget has not published live state yet.",
            "recovery": "Call open_memory_widget, wait a few seconds, then retry."
        ]
    }

    private static func boundedInt(_ value: Any?, defaultValue: Int, minimum: Int, maximum: Int) -> Int {
        let number = (value as? NSNumber)?.intValue ?? defaultValue
        return min(maximum, max(minimum, number))
    }

    private static func requestedVersion(in request: [String: Any]) -> String? {
        guard let params = request["params"] as? [String: Any],
              let meta = params["_meta"] as? [String: Any] else { return nil }
        return meta["io.modelcontextprotocol/protocolVersion"] as? String
    }

    private static func writeResult(id: Any, result: [String: Any], modern: Bool) {
        var decorated = result
        if modern {
            decorated["resultType"] = "complete"
            var meta = decorated["_meta"] as? [String: Any] ?? [:]
            meta["io.modelcontextprotocol/serverInfo"] = serverInfo
            decorated["_meta"] = meta
        }
        write(["jsonrpc": "2.0", "id": id, "result": decorated])
    }

    private static func writeError(id: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
