import Foundation

/// 多线程 Range 分片下载器（协议逆向自 kuku_pan_dl 的 Downloader）
/// - probe 探测文件大小与 Accept-Ranges
/// - 按线程数切分，每线程循环取 16MB 切片写入 .partN（控制内存峰值）
/// - 断点续传：分片文件已存在的部分跳过（.kdl.part 风格）
/// - 完成后顺序合并
final class SegmentedDownloader {

    struct Segment {
        let index: Int
        let start: Int64
        let end: Int64
        let received: Int64        // 已存在分片的大小（断点续传）
        let localURL: URL          // 本地 .partN
        let originURL: URL         // 远端下载 URL
    }

    enum SegError: LocalizedError {
        case noRange
        case badStatus(Int)
        case noSize
        case lengthMismatch
        case cancelled
        var errorDescription: String? {
            switch self {
            case .noRange: return "服务器不支持 Range 分片"
            case .badStatus(let c): return "分片请求失败 HTTP \(c)"
            case .noSize: return "无法获取文件大小"
            case .lengthMismatch: return "分片长度异常（服务器可能忽略 Range）"
            case .cancelled: return "已取消"
            }
        }
    }

    let threads: Int
    let headers: [String: String]
    private var cancelled = false
    private let lock = NSLock()

    /// 单次 Range 切片大小（16MB，控制内存峰值：8 线程 × 16MB = 128MB）
    private static let sliceSize: Int64 = 16 << 20

    init(threads: Int = 8, headers: [String: String] = [:]) {
        self.threads = max(1, min(threads, 16))
        self.headers = headers
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        cfg.httpMaximumConnectionsPerHost = threads + 2
        return URLSession(configuration: cfg)
    }

    private func apply(_ req: inout URLRequest) {
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    }

    /// 探测文件大小与是否支持 Range
    func probe(url: URL) async throws -> (size: Int64, supportsRange: Bool) {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        apply(&req)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SegError.noSize }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw SegError.badStatus(http.statusCode)
        }
        let supports = http.statusCode == 206
        // Content-Range: bytes 0-0/12345
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let total = cr.split(separator: "/").last, let n = Int64(total) {
            return (n, supports)
        }
        if let len = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(len) {
            return (n, supports)
        }
        throw SegError.noSize
    }

    private static func segSize(total: Int64, n: Int) -> Int64 {
        max(1, (total + Int64(n) - 1) / Int64(n))
    }

    /// 多线程下载到 dest。
    /// onProgress: (已下载字节, 总字节, 瞬时速度)
    func download(url: URL,
                  dest: URL,
                  totalSize: Int64,
                  onProgress: @escaping (Int64, Int64, Double) -> Void) async throws {
        guard totalSize > 0 else { throw SegError.noSize }
        let n = threads
        let seg = Self.segSize(total: totalSize, n: n)

        let fm = FileManager.default
        let partDir = dest.deletingLastPathComponent()
            .appendingPathComponent(".kdl.part_\(dest.lastPathComponent)", isDirectory: true)
        try? fm.createDirectory(at: partDir, withIntermediateDirectories: true)

        // 构造分片
        var segments: [Segment] = []
        for i in 0..<n {
            let start = Int64(i) * seg
            if start >= totalSize { break }
            let end = min(start + seg - 1, totalSize - 1)
            let partURL = partDir.appendingPathComponent("part\(i)")
            let attrs = try? fm.attributesOfItem(atPath: partURL.path)
            let exist = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            segments.append(Segment(index: i, start: start, end: end,
                                    received: exist, localURL: partURL, originURL: url))
        }

        // 已下载字节（断点续传基础）
        let baseReceived = segments.reduce(Int64(0)) { $0 + $1.received }
        let counter = ProgressCounter(initial: baseReceived, total: totalSize, onProgress: onProgress)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for s in segments {
                guard !isCancelled else { throw SegError.cancelled }
                let resumeFrom = s.start + s.received
                if resumeFrom > s.end { continue }   // 该分片已完成
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    try await self.fetchSegment(s, resumeFrom: resumeFrom, counter: counter)
                }
            }
            try await group.waitForAll()
        }

        if isCancelled { throw SegError.cancelled }

        // 合并分片
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        fm.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        for s in segments {
            let fh = try FileHandle(forReadingFrom: s.localURL)
            defer { try? fh.close() }
            while true {
                let chunk = try fh.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try out.write(contentsOf: chunk)
            }
        }
        try? fm.removeItem(at: partDir)
        counter.finish()
    }

    /// 下载一个分片：从 resumeFrom 起循环取 16MB 切片，追加写入 part 文件
    private func fetchSegment(_ s: Segment,
                              resumeFrom: Int64,
                              counter: ProgressCounter) async throws {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        if !FileManager.default.fileExists(atPath: s.localURL.path) {
            FileManager.default.createFile(atPath: s.localURL.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: s.localURL)
        defer { try? fh.close() }
        try fh.seekToEnd()

        var pos = resumeFrom
        while pos <= s.end {
            if isCancelled { throw SegError.cancelled }
            let sliceEnd = min(pos + Self.sliceSize - 1, s.end)

            var req = URLRequest(url: s.originURL)
            apply(&req)
            req.setValue("bytes=\(pos)-\(sliceEnd)", forHTTPHeaderField: "Range")

            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw SegError.noSize }
            guard http.statusCode == 206 || (http.statusCode == 200 && s.start == 0 && s.end >= pos) else {
                throw SegError.badStatus(http.statusCode)
            }
            let expected = sliceEnd - pos + 1
            if http.statusCode == 200 && Int64(data.count) > expected {
                // 服务器忽略 Range 返回了整个文件，拒绝以免数据错乱
                throw SegError.noRange
            }
            try fh.write(contentsOf: data)
            counter.add(Int64(data.count))
            pos = sliceEnd + 1
        }
    }
}

// MARK: - 进度聚合（线程安全）
private final class ProgressCounter {
    private let lock = NSLock()
    private var done: Int64
    private let total: Int64
    private let onProgress: (Int64, Int64, Double) -> Void
    private var lastDone: Int64
    private var lastTime = Date()
    private var speed: Double = 0

    init(initial: Int64, total: Int64, onProgress: @escaping (Int64, Int64, Double) -> Void) {
        self.done = initial
        self.total = total
        self.lastDone = initial
        self.onProgress = onProgress
    }

    func add(_ n: Int64) {
        lock.lock()
        done += n
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        if dt >= 0.5 {
            let inst = Double(done - lastDone) / dt
            speed = speed == 0 ? inst : speed * 0.6 + inst * 0.4
            lastDone = done
            lastTime = now
            let d = done, t = total, sp = speed
            lock.unlock()
            onProgress(d, t, sp)
            return
        }
        lock.unlock()
    }

    func finish() {
        lock.lock(); let t = total; lock.unlock()
        onProgress(t, t, 0)
    }
}
