import Foundation
import Combine
import UIKit

// MARK: - 单个下载任务的状态
enum DownloadState: Equatable {
    case queued
    case downloading
    case paused
    case finished(URL)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .downloading: return true
        default: return false
        }
    }

    /// 已开始（含暂停），用于 UI 判断是否显示进度块
    var isStarted: Bool {
        switch self {
        case .downloading, .paused: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .queued: return "排队中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - 可观察的下载体（用于 UI 绑定）
final class DownloadTask: Identifiable, ObservableObject {
    let id = UUID()
    let key: String                 // fs_id 或 name，作为去重键
    let fileName: String
    let dest: URL

    @Published var state: DownloadState = .queued
    @Published var totalBytes: Int64 = 0
    @Published var writtenBytes: Int64 = 0
    @Published var speed: Double = 0            // bytes / second
    @Published var supportsResume: Bool = true

    /// 断点续传数据（暂停/中断后用于恢复）
    var resumeData: Data?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(writtenBytes) / Double(totalBytes))
    }

    /// 是否需要在行尾显示下载控件（进度/暂停/重试）
    var showsRowControl: Bool {
        switch state {
        case .queued, .downloading, .paused, .failed: return true
        case .finished, .cancelled: return false
        }
    }

    init(key: String, fileName: String, dest: URL) {
        self.key = key
        self.fileName = fileName
        self.dest = dest
    }
}

// MARK: - 后台下载代理
/// 注意：background URLSession 的所有 delegate 回调都可能在 App 未激活时于后台线程触发，
/// 因此这里不假设 @MainActor，统一通过回调把结果送回 MainActor。
final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    /// sessionIdentifier -> 任务事件处理
    var handlers: [UUID: TaskHandler] = [:]
    private let lock = NSLock()

    struct TaskHandler {
        let onProgress: (Int64, Int64) -> Void
        let onFinish: (URL?, URLSessionDownloadTask) -> Void
        let onError: (Error?, Data?) -> Void   // 第二参：resumeData（可恢复错误时系统给出）
    }

    func register(taskID: UUID, handler: TaskHandler) {
        lock.lock(); defer { lock.unlock() }
        handlers[taskID] = handler
    }

    func unregister(taskID: UUID) {
        lock.lock(); defer { lock.unlock() }
        handlers[taskID] = nil
    }

    private func handler(for task: URLSessionTask) -> TaskHandler? {
        lock.lock(); defer { lock.unlock() }
        // 用任务描述里存的 UUID 找回
        guard let desc = task.taskDescription, let uuid = UUID(uuidString: desc) else { return nil }
        return handlers[uuid]
    }

    // 进度
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        handler(for: downloadTask)?.onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // 完成落盘
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        handler(for: downloadTask)?.onFinish(location, downloadTask)
    }

    // 错误 / 取消（含 resumeData）
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error = error else { return }  // 成功路径已由 didFinishDownloading 处理
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        handler(for: task)?.onError(error, resumeData)
    }

    // 后台 session 事件（系统唤醒 App 时）
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            if let handler = UIApplication.shared.backgroundCompletionHandler {
                handler()
                UIApplication.shared.backgroundCompletionHandler = nil
            }
        }
    }
}

// MARK: - 下载引擎（并发 + 进度 + 网速 + 断点续传 + 后台）
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    let maxConcurrent = 3

    @Published private(set) var tasks: [UUID: DownloadTask] = [:]
    @Published var finishedFiles: [URL] = []

    private var queue: [DownloadTask] = []
    private var runningCount = 0

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.qf666.pancloud.download")
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private let delegate = BackgroundDownloadDelegate()

    /// 内存里保存每个任务对应的 URLSessionDownloadTask（用于暂停/取消）
    private var liveTasks: [UUID: URLSessionDownloadTask] = [:]
    /// 每个任务的即时 provider（用于恢复时重新取 URL，若 resumeData 不可用）
    private var providers: [UUID: () async throws -> URL] = [:]
    private var headersMap: [UUID: [String: String]] = [:]

    /// 断点数据的持久化目录
    private lazy var resumeDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {
        refreshFinished()
        restorePendingTasks()
    }

    // MARK: - 公开接口

    @discardableResult
    func enqueue(
        key: String,
        fileName: String,
        provider: @escaping () async throws -> URL,
        headers: [String: String] = [:]
    ) -> DownloadTask {
        if let existing = tasks.values.first(where: { $0.key == key && $0.state.isActive }) {
            return existing
        }
        let dest = Self.safeDestination(for: fileName)
        let task = DownloadTask(key: key, fileName: fileName, dest: dest)
        tasks[task.id] = task
        providers[task.id] = provider
        headersMap[task.id] = headers
        queue.append(task)
        pump()
        return task
    }

    /// 暂停并保存断点数据
    func pause(_ id: UUID) {
        guard let task = tasks[id], task.state == .downloading else { return }
        guard let live = liveTasks[id] else { return }
        live.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                task.resumeData = data
                self.persistResume(task.id, data)
                task.state = .paused
                task.speed = 0
                self.liveTasks[id] = nil
                self.delegate.unregister(taskID: id)
                self.runningCount = max(0, self.runningCount - 1)
                self.pump()
            }
        })
    }

    /// 恢复（从暂停继续）
    func resume(_ id: UUID) {
        guard let task = tasks[id], task.state == .paused else { return }
        task.state = .queued
        // 保持队列顺序：插到队首，优先恢复
        queue.insert(task, at: 0)
        pump()
    }

    func cancel(_ id: UUID) {
        guard let task = tasks[id] else { return }
        if let live = liveTasks[id] {
            live.cancel()
        }
        liveTasks[id] = nil
        delegate.unregister(taskID: id)
        queue.removeAll { $0.id == id }
        cleanResume(id)
        if task.state.isActive || task.state == .paused {
            task.state = .cancelled
            task.speed = 0
            runningCount = max(0, runningCount - 1)
        }
        pump()
    }

    func cancelAll() {
        for id in tasks.keys { cancel(id) }
    }

    func retry(_ id: UUID) {
        guard let task = tasks[id] else { return }
        task.state = .queued
        task.writtenBytes = 0
        task.speed = 0
        // 保留 resumeData（若服务端支持 Range），否则从头
        queue.insert(task, at: 0)
        pump()
    }

    var activeTasks: [DownloadTask] {
        tasks.values.filter { $0.state.isActive }.sorted { $0.fileName < $1.fileName }
    }
    var pausedTasks: [DownloadTask] {
        tasks.values.filter { $0.state == .paused }.sorted { $0.fileName < $1.fileName }
    }

    /// 按 key 找到需要显示行尾控件的任务（供 UI 用，避免在 ViewBuilder 里做复杂推断）
    func rowTask(forKey key: String) -> DownloadTask? {
        for task in tasks.values where task.key == key {
            if task.showsRowControl { return task }
        }
        return nil
    }

    var overallSpeed: Double { activeTasks.reduce(0) { $0 + $1.speed } }

    var overallProgress: Double {
        let list = activeTasks
        guard !list.isEmpty else { return 0 }
        let total = list.reduce(Int64(0)) { $0 + max($1.totalBytes, 0) }
        guard total > 0 else { return 0 }
        let written = list.reduce(Int64(0)) { $0 + $1.writtenBytes }
        return min(1.0, Double(written) / Double(total))
    }

    // MARK: - 调度

    private func pump() {
        while runningCount < maxConcurrent, !queue.isEmpty {
            let task = queue.removeFirst()
            guard task.state == .queued else { continue }
            start(task)
        }
    }

    private func start(_ task: DownloadTask) {
        runningCount += 1
        task.state = .downloading

        Task {
            do {
                let url = try await (providers[task.id] ?? { throw URLError(.badURL) })()
                let request = makeRequest(url: url, headers: headersMap[task.id] ?? [:])
                try await self.runDownload(task: task, request: request)
            } catch {
                await MainActor.run {
                    task.state = .failed(error.localizedDescription)
                    task.speed = 0
                    self.finishRunning(task)
                }
            }
        }
    }

    private func makeRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    private func runDownload(task: DownloadTask, request: URLRequest) async throws {
        if let resumeData = task.resumeData {
            try await startWithResumeData(task: task, resumeData: resumeData, request: request)
        } else {
            try await startFresh(task: task, request: request)
        }
    }

    private func startFresh(task: DownloadTask, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let speedState = SpeedState()
            // 一次性闸门：保证 cont 只被 resume 一次（防双 resume 崩溃）
            let gate = ResumeGate()
            let handler = BackgroundDownloadDelegate.TaskHandler(
                onProgress: { written, expected in
                    Task { @MainActor in
                        if expected > 0 { task.totalBytes = expected }
                        task.writtenBytes = written
                        task.speed = speedState.update(written: written)
                    }
                },
                onFinish: { tempURL, _ in
                    Task { @MainActor in
                        self.complete(task: task, tempURL: tempURL)
                        gate.once { cont.resume() }
                    }
                },
                onError: { error, resumeData in
                    Task { @MainActor in
                        self.handleError(task: task, error: error, resumeData: resumeData)
                        gate.once { cont.resume() }
                    }
                }
            )
            delegate.register(taskID: task.id, handler: handler)

            let downloadTask = self.session.downloadTask(with: request)
            downloadTask.taskDescription = task.id.uuidString
            self.liveTasks[task.id] = downloadTask
            downloadTask.resume()
        }
    }

    private func startWithResumeData(task: DownloadTask, resumeData: Data, request: URLRequest) async throws {
        // 若 resumeData 为空/损坏，退回全新下载
        guard !resumeData.isEmpty else {
            task.resumeData = nil
            return try await startFresh(task: task, request: request)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let speedState = SpeedState()
            let gate = ResumeGate()
            let handler = BackgroundDownloadDelegate.TaskHandler(
                onProgress: { written, expected in
                    Task { @MainActor in
                        if expected > 0 { task.totalBytes = expected }
                        task.writtenBytes = written
                        task.speed = speedState.update(written: written)
                    }
                },
                onFinish: { tempURL, _ in
                    Task { @MainActor in
                        self.complete(task: task, tempURL: tempURL)
                        gate.once { cont.resume() }
                    }
                },
                onError: { error, newResumeData in
                    Task { @MainActor in
                        // 恢复失败时：若系统给了新 resumeData，丢弃旧的重来
                        if newResumeData != nil { task.resumeData = nil; self.cleanResume(task.id) }
                        self.handleError(task: task, error: error, resumeData: newResumeData)
                        gate.once { cont.resume() }
                    }
                }
            )
            delegate.register(taskID: task.id, handler: handler)

            let downloadTask = self.session.downloadTask(withResumeData: resumeData)
            downloadTask.taskDescription = task.id.uuidString
            self.liveTasks[task.id] = downloadTask
            downloadTask.resume()
        }
    }

    private func complete(task: DownloadTask, tempURL: URL?) {
        guard let tempURL = tempURL else {
            task.state = .failed("下载临时文件丢失")
            finishRunning(task)
            return
        }
        do {
            let dest = task.dest
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            task.resumeData = nil
            cleanResume(task.id)
            task.state = .finished(dest)
            task.speed = 0
            if !finishedFiles.contains(dest) { finishedFiles.insert(dest, at: 0) }
        } catch {
            task.state = .failed(error.localizedDescription)
        }
        finishRunning(task)
    }

    private func handleError(task: DownloadTask, error: Error?, resumeData: Data?) {
        if let error = error {
            if (error as? URLError)?.code == .cancelled {
                // 用户取消：若 pause 流程已处理则不覆盖状态
                if task.state == .downloading { task.state = .cancelled }
            } else {
                // 网络中断：保存 resumeData，标记为暂停（可恢复）
                if let data = resumeData, !data.isEmpty {
                    task.resumeData = data
                    persistResume(task.id, data)
                    task.state = .paused
                } else {
                    task.state = .failed(error.localizedDescription)
                }
            }
        }
        task.speed = 0
        finishRunning(task)
    }

    private func finishRunning(_ task: DownloadTask) {
        liveTasks[task.id] = nil
        delegate.unregister(taskID: task.id)
        runningCount = max(0, runningCount - 1)
        pump()
    }

    // MARK: - 断点数据持久化

    private func resumeURL(_ id: UUID) -> URL {
        resumeDir.appendingPathComponent(id.uuidString + ".resume")
    }
    private func persistResume(_ id: UUID, _ data: Data?) {
        guard let data = data else { return }
        try? data.write(to: resumeURL(id))
    }
    private func loadResume(_ id: UUID) -> Data? {
        try? Data(contentsOf: resumeURL(id))
    }
    private func cleanResume(_ id: UUID) {
        try? FileManager.default.removeItem(at: resumeURL(id))
    }

    /// 启动时扫描未完成的断点数据，恢复为"已暂停"任务
    private func restorePendingTasks() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: resumeDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "resume" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: f), !data.isEmpty else {
                try? fm.removeItem(at: f); continue
            }
            // 无对应内存任务时，仅保留断点文件，等用户重新触发时使用
            if let task = tasks[id] {
                task.resumeData = data
                task.state = .paused
            }
        }
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

    static func safeDestination(for rawName: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var name = rawName.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? "file"
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "download_\(Int(Date().timeIntervalSince1970))" }

        var dest = docs.appendingPathComponent(name)
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

// MARK: - 一次性 resume 闸门（防 CheckedContinuation 双 resume 崩溃）
/// CheckedContinuation 只允许 resume 一次；URLSession 的
/// didFinishDownloadingTo 与 didCompleteWithError 可能先后/并发触发，
/// 用此闸门保证回调体只执行一次。必须从主线程（MainActor）调用。
final class ResumeGate {
    private var fired = false
    func once(_ body: () -> Void) {
        guard !fired else { return }
        fired = true
        body()
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
        guard dt >= 0.4 else { return smoothed }
        let delta = written - lastBytes
        lastBytes = written
        lastTime = now
        guard dt > 0, delta >= 0 else { return smoothed }
        let instant = Double(delta) / dt
        smoothed = smoothed == 0 ? instant : (smoothed * 0.6 + instant * 0.4)
        return smoothed
    }
}

// MARK: - 后台完成回调挂载
extension UIApplication {
    private static var _bgHandler: (() -> Void)?
    var backgroundCompletionHandler: (() -> Void)? {
        get { UIApplication._bgHandler }
        set { UIApplication._bgHandler = newValue }
    }
}
