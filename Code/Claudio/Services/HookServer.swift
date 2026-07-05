import Foundation
import Network

/// Local HTTP server that receives Claude Code hook events.
///
/// Permission requests are held open via `CheckedContinuation` until either
/// (a) a UI action resolves them or (b) the per-request timeout fires.
/// Pending timeout tasks are cancelled on resolve so they don't linger.
actor HookServer {
    private static let port: UInt16 = 19876
    private static let permissionTimeout: Duration = .seconds(110)

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var pending: [String: PendingPermission] = [:]
    private var nextPermissionId: Int = 0

    private struct PendingPermission {
        let continuation: CheckedContinuation<HookPermissionResponse, Never>
        let timeoutTask: Task<Void, Never>
    }

    private(set) var onEvent: (@Sendable (HookEvent, String) async -> Void)?

    func setOnEvent(_ handler: @escaping @Sendable (HookEvent, String) async -> Void) {
        onEvent = handler
    }

    // MARK: - Lifecycle

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else {
            throw URLError(.badURL)
        }
        let newListener = try NWListener(using: .tcp, on: nwPort)
        self.listener = newListener

        newListener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            Task { await self?.handleConnection(conn) }
        }

        newListener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.stop() }
            }
        }

        newListener.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()

        for (_, pending) in pending {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: .deny(message: "Server stopped"))
        }
        pending.removeAll()
    }

    // MARK: - Permission resolution

    func resolvePermission(id: String, allow: Bool) {
        resolvePermission(id: id, response: allow ? .allow() : .deny(message: "Denied by user"))
    }

    func resolvePermission(id: String, response: HookPermissionResponse) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask.cancel()
        entry.continuation.resume(returning: response)
    }

    private func expirePermission(id: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(returning: .deny(message: "Permission request timed out"))
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        accumulateRequest(connection, buffer: Data())
    }

    private nonisolated func accumulateRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var buf = buffer
            if let data { buf.append(data) }

            if Self.isRequestComplete(buf) || isComplete || error != nil {
                Task { await self.processRequest(buf, connection: connection) }
            } else {
                self.accumulateRequest(connection, buffer: buf)
            }
        }
    }

    private nonisolated static func isRequestComplete(_ data: Data) -> Bool {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let separatorRange = data.firstRange(of: separator) else { return false }

        let headerData = data[data.startIndex..<separatorRange.lowerBound]
        let bodyStart = separatorRange.upperBound
        let bodyBytes = data.endIndex - bodyStart

        guard let headerString = String(data: headerData, encoding: .utf8)?.lowercased() else {
            return false
        }
        for line in headerString.split(separator: "\r\n") {
            if line.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                if let cl = Int(value) { return bodyBytes >= cl }
            }
        }
        return true
    }

    private func processRequest(_ data: Data, connection: NWConnection) async {
        defer { removeConnection(connection) }

        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse("{}", connection: connection); return
        }

        let path = parseRequestPath(raw)
        guard let event = parseBody(raw) else {
            sendResponse("{}", connection: connection); return
        }

        NotificationCenter.default.post(name: .claudioHookEvent, object: nil)

        if path.contains("/hook/permission") {
            let permissionId = "perm_\(nextPermissionId)"
            nextPermissionId += 1

            let response: HookPermissionResponse = await withCheckedContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.permissionTimeout)
                    if Task.isCancelled { return }
                    await self?.expirePermission(id: permissionId)
                }
                pending[permissionId] = PendingPermission(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    await self?.onEvent?(event, permissionId)
                }
            }

            if let body = try? JSONEncoder().encode(response),
               let bodyString = String(data: body, encoding: .utf8) {
                sendResponse(bodyString, connection: connection)
            } else {
                sendResponse("{}", connection: connection)
            }
        } else {
            await onEvent?(event, "")
            sendResponse("{}", connection: connection)
        }
    }

    // MARK: - HTTP parsing & response

    private nonisolated func parseRequestPath(_ raw: String) -> String {
        guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first else { return "" }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return String(parts[1])
    }

    private nonisolated func parseBody(_ raw: String) -> HookEvent? {
        guard let range = raw.range(of: "\r\n\r\n") else { return nil }
        let bodyString = String(raw[range.upperBound...])
        guard let bodyData = bodyString.data(using: .utf8), !bodyData.isEmpty else { return nil }
        return try? JSONDecoder().decode(HookEvent.self, from: bodyData)
    }

    private nonisolated func sendResponse(_ body: String, connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }
}

extension Notification.Name {
    static let claudioHookEvent = Notification.Name("claudioHookEvent")
}
