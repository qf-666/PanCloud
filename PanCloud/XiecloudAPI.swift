import Foundation

// MARK: - /api/parse response
struct XieParseResult: Codable {
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

    enum CodingKeys: String, CodingKey {
        case surl, bare, shareid, uk, pwd, ok, partial, done
        case count, dirs, pending, skipped, totalSize, maxBytes, error
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
    }

    // number-or-string helpers
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

// MARK: - /api/list response
struct XieListResult: Codable {
    let ok: Bool?
    let list: [XieFileItem]?
    let error: String?
}

// MARK: - one file item (tolerates string OR number fields)
struct XieFileItem: Identifiable, Codable {
    let fs_id: String
    let server_filename: String
    let isdir: Int
    let size: Int64?
    let path: String?

    var id: String { fs_id }

    enum CodingKeys: String, CodingKey {
        case fs_id, server_filename, isdir, size, path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .fs_id) {
            fs_id = s
        } else if let i = try? c.decode(UInt64.self, forKey: .fs_id) {
            fs_id = String(i)
        } else {
            fs_id = ""
        }
        server_filename = (try? c.decode(String.self, forKey: .server_filename)) ?? ""
        if let i = try? c.decode(Int.self, forKey: .isdir) {
            isdir = i
        } else if let s = try? c.decode(String.self, forKey: .isdir) {
            isdir = Int(s) ?? 0
        } else {
            isdir = 0
        }
        if let i = try? c.decode(Int64.self, forKey: .size) {
            size = i
        } else if let s = try? c.decode(String.self, forKey: .size) {
            size = Int64(s)
        } else {
            size = nil
        }
        path = try? c.decodeIfPresent(String.self, forKey: .path)
    }

    // memberwise init for manual construction
    init(fs_id: String, server_filename: String, isdir: Int, size: Int64?, path: String?) {
        self.fs_id = fs_id
        self.server_filename = server_filename
        self.isdir = isdir
        self.size = size
        self.path = path
    }
}

class XiecloudAPI {
    static let shared = XiecloudAPI()
    private let baseURL = "https://pan.xiecloud.cn"
    private let accessToken = "DK5C5-76M8K-T49H0-VN2D9"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(path: String, method: String = "POST", body: [String: Any]? = nil) -> URLRequest {
        let url = URL(string: "\(baseURL)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(accessToken, forHTTPHeaderField: "x-access-token")
        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// Step 1: submit parse task. Returns surl/shareid/uk as soon as the
    /// server accepts it (done may still be false). Retries only on transient
    /// failure (ok=false / 503 "校验服务暂不可用").
    func parse(url: String, pwd: String = "") async throws -> XieParseResult {
        let req = makeRequest(path: "/api/parse", body: ["url": url, "pwd": pwd])
        var lastError = "协云解析失败"

        for attempt in 0..<8 {
            let (data, _) = try await session.data(for: req)
            let rawStr = String(data: data.prefix(500), encoding: .utf8) ?? ""
            print("[PanCloud] xiecloud parse attempt \(attempt + 1): \(rawStr)")

            guard let result = try? JSONDecoder().decode(XieParseResult.self, from: data) else {
                lastError = "协云返回格式异常"
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }

            if result.ok == true, let surl = result.surl, !surl.isEmpty,
               let shareid = result.shareid, !shareid.isEmpty,
               let uk = result.uk, !uk.isEmpty {
                return result
            }

            lastError = result.error ?? "协云解析中(pending=\(result.pending ?? -1))"
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }

        throw NSError(domain: "XiecloudAPI", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: lastError])
    }

    /// Step 2: fetch the file list for a parsed share.
    func listFiles(surl: String, shareid: String, uk: String, pwd: String = "", dir: String = "/") async throws -> [XieFileItem] {
        var body: [String: Any] = [
            "surl": surl,
            "shareid": shareid,
            "uk": uk,
            "dir": dir
        ]
        if !pwd.isEmpty { body["pwd"] = pwd }

        let req = makeRequest(path: "/api/list", body: body)
        let (data, _) = try await session.data(for: req)

        let rawStr = String(data: data.prefix(500), encoding: .utf8) ?? ""
        print("[PanCloud] xiecloud list response: \(rawStr)")

        guard let result = try? JSONDecoder().decode(XieListResult.self, from: data) else {
            throw NSError(domain: "XiecloudAPI", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "列表返回格式异常: \(rawStr)"])
        }
        return result.list ?? []
    }

    /// Combined: parse (get surl/shareid/uk) + list. Does NOT wait for done.
    func parseAndList(url: String, pwd: String = "") async throws -> [XieFileItem] {
        let parseResult = try await parse(url: url, pwd: pwd)

        guard let surl = parseResult.surl,
              let shareid = parseResult.shareid,
              let uk = parseResult.uk else {
            throw NSError(domain: "XiecloudAPI", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "协云返回缺少必要字段"])
        }

        let actualPwd = parseResult.pwd ?? pwd
        return try await listFiles(surl: surl, shareid: shareid, uk: uk, pwd: actualPwd)
    }

    /// Submit download job, returns jobId.
    func download(surl: String, shareid: String, uk: String, items: [[String: Any]], pwd: String = "") async throws -> String {
        var body: [String: Any] = [
            "surl": surl,
            "shareid": shareid,
            "uk": uk,
            "items": items,
            "bare": false
        ]
        if !pwd.isEmpty { body["pwd"] = pwd }

        let req = makeRequest(path: "/api/download", body: body)
        let (data, _) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["jobId"] as? String ?? ""
    }

    /// Poll a download job; returns the final URL when done.
    func pollJob(id: String) async throws -> String? {
        let req = makeRequest(path: "/api/job?id=\(id)", method: "GET")
        let (data, _) = try await session.data(for: req)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = json?["status"] as? String
        if status == "done" { return json?["url"] as? String }
        return nil
    }
}
