import Foundation

struct WatchedLine: Sendable {
    let sessionPath: String
    let jsonLine: Data
}

actor SessionWatcher {
    private(set) var onNewLine: (@Sendable (WatchedLine) async -> Void)?

    func setOnNewLine(_ handler: @escaping @Sendable (WatchedLine) async -> Void) {
        onNewLine = handler
    }
    private(set) var watchedPaths: Set<String> = []
    private var watchers: [String: WatchState] = [:]
    private var lineBuffers: [String: Data] = [:]

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
                Task { await self.readAndHandle(fileHandle: fileHandle, for: sessionPath) }
            }
        }

        source.setCancelHandler {
            fileHandle.closeFile()
            close(fd)
        }

        watchers[path] = WatchState(source: source, fileHandle: fileHandle, fd: fd)
        watchedPaths.insert(path)
        lineBuffers[path] = Data()
        source.resume()
    }

    func unwatchFile(at path: String) {
        guard let state = watchers.removeValue(forKey: path) else { return }
        watchedPaths.remove(path)
        lineBuffers.removeValue(forKey: path)
        state.source.cancel()
    }

    func unwatchAll() {
        for path in Array(watchers.keys) {
            unwatchFile(at: path)
        }
    }

    /// Read from file handle on the actor to avoid concurrent access with cancel handler.
    private func readAndHandle(fileHandle: FileHandle, for sessionPath: String) async {
        guard watchers[sessionPath] != nil else { return }
        let data = fileHandle.availableData
        guard !data.isEmpty else { return }
        await handleNewData(data, for: sessionPath)
    }

    private func handleNewData(_ data: Data, for sessionPath: String) async {
        // Append to per-file buffer
        lineBuffers[sessionPath, default: Data()].append(data)

        guard var buffer = lineBuffers[sessionPath] else { return }

        let newlineByte: UInt8 = 0x0A
        var start = buffer.startIndex

        for i in buffer.indices where buffer[i] == newlineByte {
            let lineData = buffer[start..<i]
            if !lineData.isEmpty {
                let line = WatchedLine(sessionPath: sessionPath, jsonLine: Data(lineData))
                await onNewLine?(line)
            }
            start = buffer.index(after: i)
        }

        // Keep only the unconsumed remainder (partial line)
        if start < buffer.endIndex {
            buffer = Data(buffer[start...])
        } else {
            buffer = Data()
        }
        lineBuffers[sessionPath] = buffer
    }
}
