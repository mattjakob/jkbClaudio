import Foundation
import Network

actor OTelReceiver {
    private var listener: NWListener?
    private(set) var lastMetrics: [String: Double] = [:]
    var isRunning: Bool { listener != nil }

    func start(port: UInt16 = 4318) throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.handleConnection(connection)
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
    }

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data, let self else { return }
            Task { await self.processData(data) }
            self.handleConnection(connection)
        }
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
                    guard let name = metric["name"] as? String else { continue }
                    if let gauge = metric["gauge"] as? [String: Any],
                       let dataPoints = gauge["dataPoints"] as? [[String: Any]],
                       let last = dataPoints.last,
                       let value = last["asDouble"] as? Double {
                        lastMetrics[name] = value
                    }
                    if let sum = metric["sum"] as? [String: Any],
                       let dataPoints = sum["dataPoints"] as? [[String: Any]],
                       let last = dataPoints.last,
                       let value = last["asDouble"] as? Double {
                        lastMetrics[name] = value
                    }
                }
            }
        }
    }
}
