import Foundation

// MARK: - /api/parse response (new schema with files array)
struct XieParseResult: Decodable {
    let surl: String?
    let bare: String?
    let shareid: String?
    let uk: String?
    let pwd: String?
    let ok: Bool?
    let partial: Bool?
    let done: Bool?
    let count: Int?
    let dirs: Int?
    let pending: Int?
    let skipped: Int?
    let totalSize: Int64?
    let maxBytes: Int64?
    let error: String?
    let files: [XieFileItem]?

    enum CodingKeys: String, CodingKey {
        case surl, bare, shareid, uk, pwd, ok, partial, done
        case count, dirs, pending, skipped, totalSize, maxBytes, error, files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surl = try? c.decodeIfPresent(String.self, forKey: .surl)
        bare = try? c.decodeIfPresent(String.self, forKey: .bare)
        shareid = Self.str(c, .shareid)
        uk = Self.str(c, .uk)
        pwd = try? c.decodeIfPresent(String.self, forKey: .pwd)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        partial = try? c.decodeIfPresent(Bool.self, forKey: .partial)
        done = try? c.decodeIfPresent(Bool.self, forKey: .done)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
        dirs = try? c.decodeIfPresent(Int.self, forKey: .dirs)
        pending = try? c.decodeIfPresent(Int.self, forKey: .pending)
        skipped = try? c.decodeIfPresent(Int.self, forKey: .skipped)
        totalSize = Self.i64(c, .totalSize)
        maxBytes = Self.i64(c, .maxBytes)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        files = try? c.decodeIfPresent([XieFileItem].self, forKey: .files)
    }

    private static func str(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
        if let i = try? c.decodeIfPresent(Int64.self, forKey: k) { return String(i) }
        if let u = try? c.decodeIfPresent(UInt64.self, forKey: k) { return String(u) }
        return nil
    }
    private static func i64(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Int64? {
        if let i = try? c.decodeIfPresent(Int64.self, forKey: k) { return i }
        if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Int64(s) }
        return nil
    }
}

// MARK: - File item (tolerates string OR number fields)
struct XieFileItem: Identifiable, Decodable {
    let fs_id: String
    let server_filename: String
    let isdir: Int
    let size: Int64?
    let path: String?
    let md5: String?

    var id: String { fs_id }

    enum CodingKeys: String, CodingKey {
        case fs_id, server_filename, isdir, size, path, md5
        case name   // 协云实际返回 name 而非 server_filename
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .fs_id) {
            fs_id = s
        } else if let i = try? c.decode(UInt64.self, forKey: .fs_id) {
            fs_id = String(i)
        } else if let i = try? c.decode(Int64.self, forKey: .fs_id) {
            fs_id = String(i)
        } else {
            // 解码失败：生成稳定唯一 ID，避免多条撞成空串导致 List 错乱
            fs_id = "unknown_\(UUID().uuidString)"
        }
        // 文件名：百度系 server_filename，协云系 name，两者都试；最后从 path 取尾段兜底
        if let n = try? c.decode(String.self, forKey: .server_filename), !n.isEmpty {
            server_filename = n
        } else if let n = ((try? c.decode(String.self, forKey: .name)) ?? nil), !n.isEmpty {
            server_filename = n
        } else {
            let p = ((try? c.decode(String.self, forKey: .path)) ?? nil) ?? ""
            server_filename = p.split(separator: "/").last.map(String.init) ?? ""
        }
        // isdir 兼容 int / bool / string；解不出时回退到路径启发式判断
        var dirFlag: Int = -1
        if let i = try? c.decode(Int.self, forKey: .isdir) {
            dirFlag = (i == 1) ? 1 : 0
        } else if let b = try? c.decode(Bool.self, forKey: .isdir) {
            dirFlag = b ? 1 : 0
        } else if let s = try? c.decode(String.self, forKey: .isdir) {
            if let iv = Int(s) { dirFlag = (iv == 1) ? 1 : 0 }
            else if let bv = Bool(s.lowercased()) { dirFlag = bv ? 1 : 0 }
        }
        if dirFlag == -1 {
            let p = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
            let n = server_filename   // 用已含 name/path 兜底的文件名
            // 空文件名视为数据缺失（当文件），只有明确"无扩展名"或 path 以 / 结尾才判目录
            dirFlag = (p.hasSuffix("/") || (!n.isEmpty && !n.contains("."))) ? 1 : 0
        }
        isdir = dirFlag
        if let i = try? c.decode(Int64.self, forKey: .size) {
            size = i
        } else if let s = try? c.decode(String.self, forKey: .size) {
            size = Int64(s)
        } else {
            size = nil
        }
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        md5 = try? c.decodeIfPresent(String.self, forKey: .md5)
    }

    init(fs_id: String, server_filename: String, isdir: Int, size: Int64?, path: String?, md5: String? = nil) {
        self.fs_id = fs_id
        self.server_filename = server_filename
        self.isdir = isdir
        self.size = size
        self.path = path
        self.md5 = md5
    }
}

// MARK: - /api/download response
struct XieDownloadResult: Decodable {
    let ok: Bool?
    let id: String?          // new: was "jobId" before
    let stage: String?
    let detail: String?
    let error: String?
}

// MARK: - /api/job response
struct XieJobResult: Decodable {
    let ok: Bool?
    let id: String?
    let stage: String?       // "prepare" | "downloading" | "done"
    let progress: Int?
    let detail: String?
    let done: Bool?
    let links: [XieJobLink]?
    let error: String?
}

struct XieJobLink: Decodable {
    let name: String?
    let size: Int64?
    let md5: String?
}

// MARK: - /api/dl-token response
struct XieDlTokenResult: Decodable {
    let ok: Bool?
    let url: String?         // relative path like "/dl/xxxxx"
    let name: String?
    let size: Int64?
    let partSize: Int64?
    let expiresIn: Int?
    let stale: Bool?
    let error: String?
}

// MARK: - Errors
enum XieError: LocalizedError {
    case needToken
    case needCard
    case serviceUnavailable
    case parseFailed(String)
    case downloadFailed(String)
    case staleLink
    case timeout

    var errorDescription: String? {
        switch self {
        case .needToken: return "❌ Token 已过期，请更新 x-access-token"
        case .needCard: return "❌ 额度不足，请充值协云卡密"
        case .serviceUnavailable: return "⚠️ 校验服务暂不可用，请稍后重试"
        case .parseFailed(let msg): return "❌ 解析失败: \(msg)"
        case .downloadFailed(let msg): return "❌ 下载失败: \(msg)"
        case .staleLink: return "⚠️ 下载链接已失效，正在重新获取..."
        case .timeout: return "❌ 操作超时"
        }
    }
}

class XiecloudAPI {
    static let shared = XiecloudAPI()
    private let baseURL = "https://pan.xiecloud.cn"
    private let session: URLSession

    /// Read token from Info.plist (injected by CI), env, or fallback default
    var accessToken: String {
        if let plistToken = Bundle.main.object(forInfoDictionaryKey: "XieAccessToken") as? String,
           !plistToken.isEmpty {
            return plistToken
        }
        if let envToken = ProcessInfo.processInfo.environment["XIE_ACCESS_TOKEN"],
           !envToken.isEmpty {
            return envToken
        }
        return "DK5C5-76M8K-T49H0-VN2D9"
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - HTTP helpers

    private func makeRequest(path: String, method: String = "POST", body: [String: Any]? = nil) -> URLRequest {
        let url = URL(string: "\(baseURL)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = accessToken
        if !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "x-access-token")
        }
        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// Perform request and check HTTP status for auth errors
    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                // Try to distinguish needToken vs needCard
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                if body.contains("needCard") {
                    throw XieError.needCard
                }
                throw XieError.needToken
            }
            if http.statusCode == 503 {
                throw XieError.serviceUnavailable
            }
        }
        return data
    }

    // MARK: - Step 1: Parse (poll until done, returns files directly)

    /// Parse a share link. Polls until done=true or max attempts.
    /// Returns the final XieParseResult which includes the files array.
    func parse(url: String, pwd: String = "", maxAttempts: Int = 20) async throws -> XieParseResult {
        let req = makeRequest(path: "/api/parse", body: ["url": url, "pwd": pwd])
        var lastError = "协云解析失败"

        for attempt in 0..<maxAttempts {
            let data = try await perform(req)
            let rawStr = String(data: data.prefix(500), encoding: .utf8) ?? ""
            print("[PanCloud] parse attempt \(attempt + 1): \(rawStr)")

            guard let result = try? JSONDecoder().decode(XieParseResult.self, from: data) else {
                lastError = "返回格式异常"
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }

            // Check for explicit errors
            if let err = result.error {
                if err.contains("needToken") { throw XieError.needToken }
                if err.contains("needCard") { throw XieError.needCard }
                lastError = err
            }

            // 完成判断：新协议返回 ok:true + files 数组（无 done 字段）；
            // 兼容旧协议的 done==true。
            if result.done == true { return result }
            if result.ok == true && result.files != nil { return result }

            // 服务器明确失败
            if result.ok == false, let e = result.error {
                throw XieError.parseFailed(e)
            }

            try await Task.sleep(nanoseconds: 1_500_000_000)
        }

        throw XieError.parseFailed(lastError)
    }

    // MARK: - Step 2: List files in subdirectory

    /// For browsing subdirectories after initial parse.
    /// Uses /api/parse again with dir parameter (matching web behavior).
    func listFiles(surl: String, shareid: String, uk: String, pwd: String = "", dir: String = "/", bare: String? = nil) async throws -> [XieFileItem] {
        // Web version re-calls /api/parse with the same url but different dir
        // We construct a minimal body
        var body: [String: Any] = [
            "surl": surl,
            "shareid": shareid,
            "uk": uk,
            "dir": dir
        ]
        if !pwd.isEmpty { body["pwd"] = pwd }
        if let bare = bare { body["bare"] = bare }

        let req = makeRequest(path: "/api/parse", body: body)
        let data = try await perform(req)

        if let result = try? JSONDecoder().decode(XieParseResult.self, from: data) {
            if result.done == true || (result.ok == true && result.files != nil) {
                return result.files ?? []
            }
            // 服务器明确失败（ok:false，如 500"服务暂时不可用"）→ 立即抛错，绝不静默轮询
            if result.ok == false {
                let msg = result.error ?? "服务暂时不可用"
                throw XieError.parseFailed("目录访问失败: \(msg)")
            }
            // 仅"未完成"才轮询，且每轮先查明确失败
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let retryData = try await perform(req)
                if let retryResult = try? JSONDecoder().decode(XieParseResult.self, from: retryData) {
                    if retryResult.done == true || (retryResult.ok == true && retryResult.files != nil) {
                        return retryResult.files ?? []
                    }
                    if retryResult.ok == false {
                        let msg = retryResult.error ?? "服务暂时不可用"
                        throw XieError.parseFailed("目录访问失败: \(msg)")
                    }
                }
            }
            return []
        }
        // 响应体不是可识别 JSON → 立即抛错
        let raw = String(data: data.prefix(200), encoding: .utf8) ?? ""
        throw XieError.parseFailed("协云目录接口返回异常: \(raw)")
    }

    // MARK: - Step 3: Submit download job

    func submitDownload(surl: String, shareid: String, uk: String, items: [[String: Any]], pwd: String = "", bare: String? = nil) async throws -> String {
        var body: [String: Any] = [
            "surl": surl,
            "shareid": shareid,
            "uk": uk,
            "items": items
        ]
        // bare should be a string (the surl without "1" prefix), matching web behavior
        if let bare = bare {
            body["bare"] = bare
        }
        if !pwd.isEmpty { body["pwd"] = pwd }

        let req = makeRequest(path: "/api/download", body: body)
        let data = try await perform(req)
        let rawStr = String(data: data.prefix(500), encoding: .utf8) ?? ""
        print("[PanCloud] download submit: \(rawStr)")

        guard let result = try? JSONDecoder().decode(XieDownloadResult.self, from: data) else {
            throw XieError.downloadFailed("提交下载请求格式异常")
        }

        if result.ok != true {
            throw XieError.downloadFailed(result.error ?? "未知错误")
        }

        guard let jobId = result.id, !jobId.isEmpty else {
            throw XieError.downloadFailed("未返回任务 ID")
        }
        return jobId
    }

    // MARK: - Step 4: Poll job until done

    func pollJob(id: String, maxAttempts: Int = 60) async throws -> XieJobResult {
        let req = makeRequest(path: "/api/job?id=\(id)", method: "GET")

        for attempt in 0..<maxAttempts {
            let data = try await perform(req)
            let rawStr = String(data: data.prefix(300), encoding: .utf8) ?? ""
            print("[PanCloud] job poll \(attempt + 1): \(rawStr)")

            guard let result = try? JSONDecoder().decode(XieJobResult.self, from: data) else {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }

            if result.ok == false {
                let err = result.error ?? ""
                if err.contains("不存在") || err.contains("过期") {
                    throw XieError.downloadFailed(err)
                }
            }

            if result.stage == "done" || result.done == true {
                return result
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        throw XieError.timeout
    }

    // MARK: - Step 5: Get download token (real URL)

    func getDlToken(jobId: String, name: String, md5: String? = nil, bare: String? = nil, maxRetries: Int = 10) async throws -> URL {
        var body: [String: Any] = [
            "jobId": jobId,
            "name": name
        ]
        if let md5 = md5, !md5.isEmpty { body["md5"] = md5 }
        if let bare = bare { body["bare"] = bare }

        let req = makeRequest(path: "/api/dl-token", body: body)

        for attempt in 0..<maxRetries {
            let data = try await perform(req)
            let rawStr = String(data: data.prefix(300), encoding: .utf8) ?? ""
            print("[PanCloud] dl-token \(attempt + 1): \(rawStr)")

            guard let result = try? JSONDecoder().decode(XieDlTokenResult.self, from: data) else {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }

            if result.stale == true {
                // Link is being regenerated, wait and retry
                print("[PanCloud] dl-token stale, retrying...")
                try await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }

            if result.ok == true, let relPath = result.url {
                let fullUrl = "\(baseURL)\(relPath)"
                if let url = URL(string: fullUrl) {
                    return url
                }
                throw XieError.downloadFailed("下载 URL 格式无效: \(fullUrl)")
            }

            if let err = result.error {
                throw XieError.downloadFailed(err)
            }

            try await Task.sleep(nanoseconds: 3_000_000_000)
        }

        throw XieError.downloadFailed("获取下载链接超时")
    }

    // MARK: - Context for UI

    struct XieShareContext {
        let surl: String
        let bare: String?
        let shareid: String
        let uk: String
        let pwd: String
    }

    // MARK: - High-level: Parse + get context + files

    func parseAndGetContext(url: String, pwd: String = "") async throws -> (context: XieShareContext, files: [XieFileItem]) {
        let result = try await parse(url: url, pwd: pwd)

        guard let surl = result.surl,
              let shareid = result.shareid,
              let uk = result.uk else {
            throw XieError.parseFailed("缺少必要字段 (surl/shareid/uk)")
        }

        let actualPwd = result.pwd ?? pwd
        let files = result.files ?? []
        let context = XieShareContext(surl: surl, bare: result.bare, shareid: shareid, uk: uk, pwd: actualPwd)

        return (context, files)
    }

    // MARK: - High-level: Download one file end-to-end

    func downloadFile(context: XieShareContext, file: XieFileItem) async throws -> URL {
        let urls = try await downloadFiles(context: context, files: [file])
        guard let first = urls.first else { throw XieError.downloadFailed("未获取到下载链接") }
        return first
    }

    /// 批量：一次 submit 多个 item（服务端 items 本就是数组），再统一取 token
    func downloadFiles(context: XieShareContext, files: [XieFileItem]) async throws -> [URL] {
        guard !files.isEmpty else { return [] }
        let items: [[String: Any]] = files.map { f in
            [
                "fs_id": f.fs_id as Any,
                "name": f.server_filename as Any,
                "path": (f.path ?? "") as Any,
                "size": (f.size ?? 0) as Any,
                "md5": (f.md5 ?? "") as Any
            ]
        }

        let jobId = try await submitDownload(
            surl: context.surl,
            shareid: context.shareid,
            uk: context.uk,
            items: items,
            pwd: context.pwd,
            bare: context.bare
        )

        _ = try await pollJob(id: jobId)

        var urls: [URL] = []
        for f in files {
            let u = try await getDlToken(
                jobId: jobId,
                name: f.server_filename,
                md5: f.md5,
                bare: context.bare
            )
            urls.append(u)
        }
        return urls
    }

    func downloadFileLegacy(context: XieShareContext, file: XieFileItem) async throws -> URL {
        let items: [[String: Any]] = [[
            "fs_id": file.fs_id,
            "name": file.server_filename,
            "path": file.path ?? "",
            "size": file.size ?? 0,
            "md5": file.md5 ?? ""
        ]]

        // Step 3: submit download
        let jobId = try await submitDownload(
            surl: context.surl,
            shareid: context.shareid,
            uk: context.uk,
            items: items,
            pwd: context.pwd,
            bare: context.bare
        )

        // Step 4: poll until done
        _ = try await pollJob(id: jobId)

        // Step 5: get real download URL via dl-token
        let dlUrl = try await getDlToken(
            jobId: jobId,
            name: file.server_filename,
            md5: file.md5,
            bare: context.bare
        )

        return dlUrl
    }

    // MARK: - Card info (for UI display)

    struct CardInfo: Codable {
        let ok: Bool?
        let kind: String?
        let unit: String?
        let amount: Int?
        let used: Int?
        let left: Int?
        let expiresAt: Int64?
    }

    func fetchCardInfo() async throws -> CardInfo? {
        let req = makeRequest(path: "/api/card/info", method: "GET")
        let data = try await perform(req)
        return try? JSONDecoder().decode(CardInfo.self, from: data)
    }

    // MARK: - Extract password from text (matches web behavior)

    /// Auto-extract pwd from various formats:
    /// - URL param: ?pwd=xxxx
    /// - Chinese text: 提取码:xxxx / 密码:xxxx
    /// - Fallback: last standalone 4-char alphanumeric in text
    static func extractPassword(from text: String) -> String {
        // 1. URL parameter ?pwd=
        if let range = text.range(of: "pwd=") {
            let after = text[range.upperBound...]
            let code = String(after.prefix(while: { $0.isLetter || $0.isNumber }))
            if !code.isEmpty { return code }
        }

        // 2. Chinese patterns: 提取码: / 提取码： / 密码: / 密码：
        let patterns = ["提取码：", "提取码:", "提取码 ", "密码：", "密码:", "密码 "]
        for pat in patterns {
            if let range = text.range(of: pat) {
                let after = text[range.upperBound...]
                    .drop(while: { $0 == " " || $0 == "\t" })
                let code = String(after.prefix(4))
                if code.count >= 3 && code.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    return code
                }
            }
        }

        // 3. Fallback: find standalone 4-char alnum (but NOT inside the surl)
        // Only match if preceded by space/punctuation or start-of-string
        let regex = try? NSRegularExpression(pattern: "(?:^|[\\s:：=])([a-zA-Z0-9]{4})(?:[\\s,，。!?]|$)", options: [])
        let nsText = text as NSString
        let matches = regex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []
        if let lastMatch = matches.last, lastMatch.numberOfRanges > 1 {
            let code = nsText.substring(with: lastMatch.range(at: 1))
            // Avoid matching parts of the surl itself
            if !text.contains("/s/\(code)") {
                return code
            }
        }

        return ""
    }
}
