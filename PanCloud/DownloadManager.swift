import Foundation
import Combine
import UIKit

// MARK: - 单个下载任务的状态
enum DownloadState: Equatable {
    case queued
    case downloading
    case finished(URL)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .downloading: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .queued: return "排队中"
        case .downloading: return "下载中"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - 可观察的下载体（用于 UI 绑定）
final class DownloadTask: Identifiable, ObservableObject {
    let id = UUID()
    let key: String                 // 用 fs_id 或 dlink 作为去重键
    let fileName: String
    let dest: URL

    @Published var state: DownloadState = .queued
    @Published var totalBytes: Int64 = 0
    @Published var writtenBytes: Int64 = 0
    @Published var speed: Double = 0            // bytes / second

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(writtenBytes) / Double(totalBytes))
    }

    init(key: String, fileName: String, dest: URL) {
        self.key = key
        self.fileName = fileName
        self.dest = dest
    }
}

// MARK: - 下载进度代理
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Int64, Int64) -> Void
    let onFinish: (URL?) -> Void
    let onError: (Error?) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void,
         onFinish: @escaping (URL?) -> Void,
         onError: @escaping (Error?) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        self.onError = onError
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        onFinish(location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error { onError(error) }
    }
}

// MARK: - 下载引擎（并发队列 + 进度 + 网速）
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// 最多同时下载数
    let maxConcurrent = 3

    @Published private(set) var tasks: [UUID: DownloadTask] = [:]
    /// 已完成文件（供"文件"页展示）
    @Published var finishedFiles: [URL] = []

    private var queue: [DownloadTask] = []
    private var runningCount = 0
    private var sessions: [UUID: URLSession] = [:]
    private var delegates: [UUID: ProgressDelegate] = [:]

    private init() {
        refreshFinished()
    }

    // MARK: - 公开接口

    /// 批量入队。provider 负责把一条任务换成真实下载 URL（含过期重取逻辑）。
    @discardableResult
    func enqueue(
        key: String,
        fileName: String,
        provider: @escaping () async throws -> URL,
        headers: [String: String] = [:]
    ) -> DownloadTask {
        // 去重：同一文件正在下载则不重复加
        if let existing = tasks.values.first(where: { $0.key == key && $0.state.isActive }) {
            return existing
        }

        let dest = Self.safeDestination(for: fileName)
        let task = DownloadTask(key: key, fileName: fileName, dest: dest)
        tasks[task.id] = task
        queue.append(task)
        pump(provider: provider, headers: headers)
        return task
    }

    func cancel(_ id: UUID) {
        guard let task = tasks[id] else { return }
        if let session = sessions[id] {
            session.invalidateAndCancel()
        }
        sessions[id] = nil
        delegates[id] = nil
        queue.removeAll { $0.id == id }
        if task.state.isActive {
            task.state = .cancelled
            runningCount = max(0, runningCount - 1)
        }
        pumpPending()
    }

    func cancelAll() {
        for id in tasks.keys { cancel(id) }
    }

    /// 当前活跃任务
    var activeTasks: [DownloadTask] {
        tasks.values.filter { $0.state.isActive }.sorted { $0.fileName < $1.fileName }
    }

    var overallSpeed: Double {
        activeTasks.reduce(0) { $0 + $1.speed }
    }

    var overallProgress: Double {
        let list = activeTasks
        guard !list.isEmpty else { return 0 }
        let total = list.reduce(Int64(0)) { $0 + max($1.totalBytes, 0) }
        guard total > 0 else { return 0 }
        let written = list.reduce(Int64(0)) { $0 + $1.writtenBytes }
        return min(1.0, Double(written) / Double(total))
    }

    // MARK: - 调度

    private func pumpPending() {
        while runningCount < maxConcurrent, !queue.isEmpty {
            let task = queue.removeFirst()
            guard task.state == .queued else { continue }
            start(task)
        }
    }

    private func pump(provider: @escaping () async throws -> URL,
                      headers: [String: String]) {
        while runningCount < maxConcurrent, !queue.isEmpty {
            let task = queue.removeFirst()
            guard task.state == .queued else { continue }
            start(task, provider: provider, headers: headers)
        }
    }

    private func start(_ task: DownloadTask,
                       provider: (() async throws -> URL)? = nil,
                       headers: [String: String] = [:]) {
        runningCount += 1
        task.state = .downloading

        Task {
            do {
                let url = try await (provider ?? { throw URLError(.badURL) })()
                try await self.runDownload(task: task, url: url, headers: headers)
            } catch {
                await MainActor.run {
                    task.state = .failed(error.localizedDescription)
                    task.speed = 0
                    self.finishRunning(task)
                }
            }
        }
    }

    private func runDownload(task: DownloadTask, url: URL, headers: [String: String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let state = SpeedState()
            let delegate = ProgressDelegate(
                onProgress: { written, expected in
                    Task { @MainActor in
                        if expected > 0 { task.totalBytes = expected }
                        task.writtenBytes = written
                        task.speed = state.update(written: written)
                    }
                },
                onFinish: { tempURL in
                    Task { @MainActor in
                        guard let tempURL = tempURL else {
                            task.state = .failed("下载临时文件丢失")
                            self.finishRunning(task)
                            cont.resume()
                            return
                        }
                        do {
                            let dest = task.dest
                            if FileManager.default.fileExists(atPath: dest.path) {
                                let backup = dest.deletingLastPathComponent()
                                    .appendingPathComponent(".old_\(UUID().uuidString)_\(dest.lastPathComponent)")
                                try? FileManager.default.moveItem(at: dest, to: backup)
                                try? FileManager.default.removeItem(at: backup)
                            }
                            try FileManager.default.moveItem(at: tempURL, to: dest)
                            task.state = .finished(dest)
                            task.speed = 0
                            self.finishedFiles.insert(dest, at: 0)
                        } catch {
                            task.state = .failed(error.localizedDescription)
                        }
                        self.finishRunning(task)
                        cont.resume()
                    }
                },
                onError: { error in
                    Task { @MainActor in
                        if let error = error {
                            if (error as? URLError)?.code == .cancelled {
                                task.state = .cancelled
                            } else {
                                task.state = .failed(error.localizedDescription)
                            }
                        }
                        task.speed = 0
                        self.finishRunning(task)
                        cont.resume()
                    }
                }
            )

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            self.delegates[task.id] = delegate
            self.sessions[task.id] = session

            var request = URLRequest(url: url)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let downloadTask = session.downloadTask(with: request)
            downloadTask.resume()
        }
    }

    private func finishRunning(_ task: DownloadTask) {
        sessions[task.id]?.finishTasksAndInvalidate()
        sessions[task.id] = nil
        delegates[task.id] = nil
        runningCount = max(0, runningCount - 1)
        pumpPending()
    }

    // MARK: - 本地文件

    func refreshFinished() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        finishedFiles = files.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 > d1
        }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        finishedFiles.removeAll { $0 == url }
    }

    // MARK: - 工具

    /// 只取文件名，剥掉路径分隔符/控制字符，避免写入非预期路径
    static func safeDestination(for rawName: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var name = rawName.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? "file"
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "download_\(Int(Date().timeIntervalSince1970))" }

        var dest = docs.appendingPathComponent(name)
        // 冲突则加 (n)
        if FileManager.default.fileExists(atPath: dest.path) {
            let ext = dest.pathExtension
            let base = dest.deletingPathExtension().lastPathComponent
            var i = 1
            repeat {
                let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
                dest = docs.appendingPathComponent(candidate)
                i += 1
            } while FileManager.default.fileExists(atPath: dest.path) && i < 1000
        }
        return dest
    }

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "-- KB/s" }
        let kb = bytesPerSec / 1024
        if kb >= 1024 { return String(format: "%.2f MB/s", kb / 1024) }
        return String(format: "%.0f KB/s", kb)
    }

    static func formatSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: max(0, bytes))
    }
}

// MARK: - 网速计算（滑动窗口，带节流）
private final class SpeedState {
    private var lastBytes: Int64 = 0
    private var lastTime = Date()
    private var smoothed: Double = 0

    func update(written: Int64) -> Double {
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        guard dt >= 0.4 else { return smoothed }   // 节流，避免抖动
        let delta = written - lastBytes
        lastBytes = written
        lastTime = now
        guard dt > 0, delta >= 0 else { return smoothed }
        let instant = Double(delta) / dt
        smoothed = smoothed == 0 ? instant : (smoothed * 0.6 + instant * 0.4)
        return smoothed
    }
}
