import CryptoKit
import Foundation
import Observation

/// Fetches the open-source models once. A background session keeps going if you switch apps,
/// and every file's checksum is verified before it's used.
@MainActor @Observable
final class ModelDownloads: NSObject {
    static let shared = ModelDownloads()

    enum State: Equatable {
        case absent
        case downloading(Double)
        case verifying
        case installed
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var session: URLSession!

    override private init() {
        super.init()
        // The smaller transcription model it replaced.
        try? FileManager.default.removeItem(at: ModelFile.directory.appendingPathComponent("ggml-base.en.bin"))
        let configuration = URLSessionConfiguration.background(withIdentifier: "margin.models")
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        for file in Self.all {
            states[file.name] = file.isInstalled ? .installed : .absent
        }
        // A download started before the app last quit is still running, so pick it back up.
        session.getAllTasks { tasks in
            let names = tasks.compactMap(\.taskDescription)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for file in Self.all where names.contains(file.name) && !file.isInstalled {
                        self.states[file.name] = .downloading(0)
                    }
                }
            }
        }
    }

    private static let all = [ModelFile.writing, ModelFile.speech, ModelFile.speechWorld]
    private nonisolated static func file(for task: URLSessionTask) -> ModelFile? {
        [ModelFile.writing, ModelFile.speech, ModelFile.speechWorld].first { $0.name == task.taskDescription }
    }

    func state(of file: ModelFile) -> State { states[file.name] ?? .absent }
    func isInstalled(_ file: ModelFile) -> Bool { states[file.name] == .installed || file.isInstalled }

    func download(_ file: ModelFile) {
        let task = session.downloadTask(with: file.url)
        task.taskDescription = file.name
        states[file.name] = .downloading(0)
        task.resume()
    }

    func remove(_ file: ModelFile) {
        try? FileManager.default.removeItem(at: file.path)
        states[file.name] = .absent
        if file.name == ModelFile.writing.name { LocalLLM.shared.unload() }
    }

    private func install(_ downloaded: URL, as file: ModelFile) {
        let fm = FileManager.default
        // The system deletes this temporary file when the delegate call returns, so claim it first.
        let holding = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fm.moveItem(at: downloaded, to: holding)
        } catch {
            states[file.name] = .failed("Couldn't save the download.")
            return
        }
        states[file.name] = .verifying
        Task {
            let matches = await Task.detached(priority: .utility) { Self.checksum(of: holding) == file.sha256 }.value
            guard matches else {
                try? fm.removeItem(at: holding)
                states[file.name] = .failed("The download was damaged. Try again.")
                return
            }
            do {
                try fm.createDirectory(at: ModelFile.directory, withIntermediateDirectories: true)
                try? fm.removeItem(at: file.path)
                try fm.moveItem(at: holding, to: file.path)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true // it can always be fetched again, so it shouldn't fill iCloud
                var installed = file.path
                try installed.setResourceValues(values)
                states[file.name] = .installed
            } catch {
                try? fm.removeItem(at: holding)
                states[file.name] = .failed("Couldn't install the model: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func checksum(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try? handle.read(upToCount: 8 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let file = Self.file(for: downloadTask) else { return }
        MainActor.assumeIsolated {
            states[file.name] = .downloading(Double(totalBytesWritten) / Double(file.bytes))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let file = Self.file(for: downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // Runs on the main queue (see delegateQueue) and must take the file before returning.
        MainActor.assumeIsolated {
            guard status == 200 else {
                states[file.name] = .failed("The download failed (error \(status)).")
                return
            }
            install(location, as: file)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let file = Self.file(for: task), let message = error?.localizedDescription else { return }
        MainActor.assumeIsolated {
            states[file.name] = .failed(message)
        }
    }
}
