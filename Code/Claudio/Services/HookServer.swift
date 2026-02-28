import Foundation
import Network

actor HookServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var pendingPermissions: [String: CheckedContinuation<HookPermissionResponse, Never>] = [:]
    private var nextPermissionId: Int = 0

    private(set) var onEvent: (@Sendable (HookEvent, String) async -> Void)?

    func setOnEvent(_ handler: @escaping @Sendable (HookEvent, String) async -> Void) {
        onEvent = handler
    }

    func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: 19876) else {
            throw URLError(.badURL)
        }
        let params = NWParameters.tcp
        let newListener = try NWListener(using: params, on: port)
        self.listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { await self?.handleConnection(connection) }
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
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()

        for (_, continuation) in pendingPermissions {
            continuation.resume(returning: .deny(message: "Server stopped"))
        }
        pendingPermissions.removeAll()
    }

    func resolvePermission(id: String, allow: Bool) {
        guard let continuation = pendingPermissions.removeValue(forKey: id) else { return }
        if allow {
            continuation.resume(returning: .allow())
        } else {
            continuation.resume(returning: .deny(message: "Denied by user"))
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        accumulateRequest(connection, buffer: Data())
    }

    /// Reads data from the connection until the full HTTP request (headers + Content-Length body) is received.
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

    /// Checks whether the accumulated buffer contains a complete HTTP request.
    private nonisolated static func isRequestComplete(_ data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else {
            return false
        }

        let headers = raw[..<headerEnd.lowerBound].lowercased()
        let bodyBytes = raw[headerEnd.upperBound...].utf8.count

        // Parse Content-Length from headers
        for line in headers.split(separator: "\r\n") {
            if line.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                if let cl = Int(value) {
                    return bodyBytes >= cl
                }
            }
        }

        // No Content-Length — treat what we have as complete
        return true
    }

    private func processRequest(_ data: Data, connection: NWConnection) async {
        defer { removeConnection(connection) }

        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse("{}", connection: connection)
            return
        }

        let path = parseRequestPath(raw)
        let event = parseBody(raw)

        guard let event else {
            sendResponse("{}", connection: connection)
            return
        }

        let isPermission = path.contains("/hook/permission")

        if isPermission {
            let permissionId = "perm_\(nextPermissionId)"
            nextPermissionId += 1

            await onEvent?(event, permissionId)

            let response: HookPermissionResponse = await withCheckedContinuation { continuation in
                pendingPermissions[permissionId] = continuation

                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(110))
                    await self?.expirePermission(id: permissionId)
                }
            }

            guard let body = try? JSONEncoder().encode(response),
                  let bodyString = String(data: body, encoding: .utf8) else {
                sendResponse("{}", connection: connection)
                return
            }
            sendResponse(bodyString, connection: connection)
        } else {
            await onEvent?(event, "")
            sendResponse("{}", connection: connection)
        }
    }

    private func expirePermission(id: String) {
        guard let continuation = pendingPermissions.removeValue(forKey: id) else { return }
        continuation.resume(returning: .deny(message: "Permission request timed out"))
    }

    // MARK: - HTTP parsing

    private nonisolated func parseRequestPath(_ raw: String) -> String {
        guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first else {
            return ""
        }
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

    // MARK: - HTTP response

    private nonisolated func sendResponse(_ body: String, connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let data = Data(response.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }
}
