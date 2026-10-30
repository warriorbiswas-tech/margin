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
    @ObservationIgnored private var files: [Int: ModelFile] = [:]
    @ObservationIgnored private var session: URLSession!

    override private init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: "margin.models")
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        for file in [ModelFile.writing, ModelFile.speech] {
            states[file.name] = file.isInstalled ? .installed : .absent
        }
    }

    func state(of file: ModelFile) -> State { states[file.name] ?? .absent }

    func download(_ file: ModelFile) {
        let task = session.downloadTask(with: file.url)
        files[task.taskIdentifier] = file
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
        let id = downloadTask.taskIdentifier
        MainActor.assumeIsolated {
            guard let file = files[id] else { return }
            states[file.name] = .downloading(Double(totalBytesWritten) / Double(file.bytes))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // Runs on the main queue (see delegateQueue) and must take the file before returning.
        MainActor.assumeIsolated {
            guard let file = files[id] else { return }
            guard status == 200 else {
                states[file.name] = .failed("The download failed (error \(status)).")
                return
            }
            install(location, as: file)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            guard let file = files[id] else { return }
            files[id] = nil
            if let message { states[file.name] = .failed(message) }
        }
    }
}
