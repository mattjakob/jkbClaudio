import Foundation
import Network

actor OTelReceiver {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    var isRunning: Bool { listener != nil }

    func start(port: UInt16 = 4318) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { await self?.addConnection(connection) }
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
    }

    private func addConnection(_ connection: NWConnection) {
        connections.append(connection)
        readLoop(connection)
    }

    private nonisolated func readLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            if let data, let self {
                Task { await self.processData(data) }
            }
            if isComplete {
                connection.cancel()
                Task { await self?.removeConnection(connection) }
            } else if data != nil {
                self?.readLoop(connection)
            } else {
                // Error with no data and not complete — clean up
                connection.cancel()
                Task { await self?.removeConnection(connection) }
            }
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }

    private func processData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceMetrics = json["resourceMetrics"] as? [[String: Any]] else {
            return
        }

        for rm in resourceMetrics {
            guard let scopeMetrics = rm["scopeMetrics"] as? [[String: Any]] else { continue }
            for sm in scopeMetrics {
                guard let metrics = sm["metrics"] as? [[String: Any]] else { continue }
                for metric in metrics {
                    guard metric["name"] is String else { continue }
                    // Metrics parsed but not currently consumed — placeholder for future use
                }
            }
        }
    }
}
