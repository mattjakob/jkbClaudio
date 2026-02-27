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
        guard let port = NWEndpoint.Port(rawValue: 19876) else {
            throw URLError(.badURL)
        }
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { await self?.handleConnection(connection) }
        }

        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.stop() }
            }
        }

        listener.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()

        for (id, continuation) in pendingPermissions {
            continuation.resume(returning: .deny(message: "Server stopped"))
            pendingPermissions.removeValue(forKey: id)
        }
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
        readRequest(connection)
    }

    private nonisolated func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data else {
                connection.cancel()
                return
            }
            Task { await self.processRequest(data, connection: connection) }
        }
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

    private func parseRequestPath(_ raw: String) -> String {
        guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first else {
            return ""
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return String(parts[1])
    }

    private func parseBody(_ raw: String) -> HookEvent? {
        guard let range = raw.range(of: "\r\n\r\n") else { return nil }
        let bodyString = String(raw[range.upperBound...])
        guard let bodyData = bodyString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HookEvent.self, from: bodyData)
    }

    // MARK: - HTTP response

    private nonisolated func sendResponse(_ body: String, connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let data = Data(response.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }
}
