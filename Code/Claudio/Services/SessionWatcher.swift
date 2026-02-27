import Foundation

struct WatchedLine: Sendable {
    let sessionPath: String
    let jsonLine: Data
}

actor SessionWatcher {
    var onNewLine: (@Sendable (WatchedLine) async -> Void)?
    private(set) var watchedPaths: Set<String> = []
    private var watchers: [String: WatchState] = [:]

    private struct WatchState {
        let source: DispatchSourceFileSystemObject
        let fileHandle: FileHandle
        let fd: Int32
    }

    func watchFile(at path: String) {
        guard watchers[path] == nil else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        fileHandle.seekToEndOfFile()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .write, .delete, .rename],
            queue: .global()
        )

        let sessionPath = path

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                Task { await self.unwatchFile(at: sessionPath) }
                return
            }
            if events.contains(.extend) || events.contains(.write) {
                let data = fileHandle.availableData
                guard !data.isEmpty else { return }
                Task { await self.handleNewData(data, for: sessionPath) }
            }
        }

        source.setCancelHandler {
            fileHandle.closeFile()
            close(fd)
        }

        watchers[path] = WatchState(source: source, fileHandle: fileHandle, fd: fd)
        watchedPaths.insert(path)
        source.resume()
    }

    func unwatchFile(at path: String) {
        guard let state = watchers.removeValue(forKey: path) else { return }
        watchedPaths.remove(path)
        state.source.cancel()
    }

    func unwatchAll() {
        for path in Array(watchers.keys) {
            unwatchFile(at: path)
        }
    }

    private func handleNewData(_ data: Data, for sessionPath: String) async {
        let newlineByte: UInt8 = 0x0A
        var start = data.startIndex

        for i in data.indices where data[i] == newlineByte {
            let lineData = data[start..<i]
            if !lineData.isEmpty {
                let line = WatchedLine(sessionPath: sessionPath, jsonLine: Data(lineData))
                await onNewLine?(line)
            }
            start = data.index(after: i)
        }

        // Handle trailing data without a newline
        if start < data.endIndex {
            let lineData = data[start..<data.endIndex]
            if !lineData.isEmpty {
                let line = WatchedLine(sessionPath: sessionPath, jsonLine: Data(lineData))
                await onNewLine?(line)
            }
        }
    }
}
