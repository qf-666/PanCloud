import Foundation

struct PanFile: Identifiable, Codable {
    var id: String { String(fsId) }
    let fsId: UInt64
    let serverFilename: String
    let path: String
    let isDir: Int
    let size: Int64
    let dlink: String?
    
    init(fsId: UInt64, serverFilename: String, path: String, isDir: Int, size: Int64, dlink: String?) {
        self.fsId = fsId
        self.serverFilename = serverFilename
        self.path = path
        self.isDir = isDir
        self.size = size
        self.dlink = dlink
    }
    
    enum CodingKeys: String, CodingKey {
        case fsId = "fs_id"
        case serverFilename = "server_filename"
        case path
        case isDir = "isdir"
        case size
        case dlink
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Baidu returns fs_id/isdir/size as strings, not numbers
        if let fsStr = try? c.decode(String.self, forKey: .fsId) {
            self.fsId = UInt64(fsStr) ?? 0
        } else {
            self.fsId = try c.decode(UInt64.self, forKey: .fsId)
        }
        self.serverFilename = (try? c.decode(String.self, forKey: .serverFilename)) ?? ""
        self.path = (try? c.decode(String.self, forKey: .path)) ?? ""
        if let dirStr = try? c.decode(String.self, forKey: .isDir) {
            self.isDir = Int(dirStr) ?? 0
        } else {
            self.isDir = try c.decode(Int.self, forKey: .isDir)
        }
        if let sizeStr = try? c.decode(String.self, forKey: .size) {
            self.size = Int64(sizeStr) ?? 0
        } else {
            self.size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        }
        self.dlink = try c.decodeIfPresent(String.self, forKey: .dlink)
    }
}

struct ShareInfo {
    let surl: String
    let shareId: String
    let uk: String
    let pwd: String
}

enum APIError: Error, LocalizedError {
    case noCookie
    case parseFailed(String)
    case httpError(Int)
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .noCookie: return "请先填写完整的 Cookie"
        case .parseFailed(let m): return "解析失败: \(m)"
        case .httpError(let c): return "HTTP \(c)"
        case .networkError(let e): return e.localizedDescription
        }
    }
}

class BaiduPanAPI {
    static let shared = BaiduPanAPI()
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
    
    func parseShareLink(_ link: String) -> ShareInfo? {
        var surl = ""
        var pwd = ""
        
        // 提取 surl
        if let range = link.range(of: "/s/1") {
            let after = String(link[range.upperBound...])
            let clean = after.components(separatedBy: CharacterSet(charactersIn: "?# \n\t")).first ?? after
            surl = "1" + clean
        } else if let range = link.range(of: "surl=") {
            let after = String(link[range.upperBound...])
            surl = after.components(separatedBy: CharacterSet(charactersIn: "&#\n\t")).first ?? after
        }
        
        // 1. URL参数 ?pwd=xxxx
        if let range = link.range(of: "pwd=") {
            let after = String(link[range.upperBound...])
            pwd = after.components(separatedBy: CharacterSet(charactersIn: "&#\n\t ")).first ?? after
        }
        // 2. "提取码：abcd" / "提取码: abcd" / "提取码 abcd"
        if pwd.isEmpty {
            for pat in ["提取码：", "提取码:", "提取码 "] {
                if let range = link.range(of: pat), range.upperBound < link.endIndex {
                    let after = String(link[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "：: \t\n"))
                    let code = String(after.prefix(4))
                    if code.count >= 3 { pwd = code; break }
                }
            }
        }
        // 3. "密码：abcd" / "密码: abcd"
        if pwd.isEmpty {
            for pat in ["密码：", "密码:", "密码 "] {
                if let range = link.range(of: pat), range.upperBound < link.endIndex {
                    let after = String(link[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "：: \t\n"))
                    let code = String(after.prefix(4))
                    if code.count >= 3 { pwd = code; break }
                }
            }
        }
        // 4. 正则兜底：只认带"提取码/密码/pwd/code"等前缀上下文的4位码，避免误判年份/路径数字
        if pwd.isEmpty {
            let nsStr = link as NSString
            let patterns = [
                "(?:提取码|密\\s*码|访问码|密码|pwd|passcode|code)[\\s:：=]{0,3}([a-zA-Z0-9]{4})(?![a-zA-Z0-9])",
                "(?:^|[\\s:：=])([a-zA-Z0-9]{4})(?=\\s*$)"
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let matches = regex.matches(in: link, options: [], range: NSRange(location: 0, length: nsStr.length))
                    if let lastMatch = matches.last {
                        let codeRange = lastMatch.range(at: 1)
                        if codeRange.location != NSNotFound {
                            let candidate = nsStr.substring(with: codeRange)
                            // 排除纯数字且像年份（19xx/20xx）的候选
                            if !(candidate.count == 4 && candidate.allSatisfy({ $0.isNumber }) && (candidate.hasPrefix("19") || candidate.hasPrefix("20"))) {
                                pwd = candidate
                                break
                            }
                        }
                    }
                }
            }
        }
        
        guard !surl.isEmpty else { return nil }
        return ShareInfo(surl: surl, shareId: "", uk: "", pwd: pwd)
    }
    
    func listFiles(info: ShareInfo, cookie: String, dir: String = "/") async throws -> [PanFile] {
        guard !cookie.isEmpty else { throw APIError.noCookie }
        
        var components = URLComponents(string: "https://pan.baidu.com/share/wxlist")!
        components.queryItems = [
            URLQueryItem(name: "channel", value: "weixin"),
            URLQueryItem(name: "version", value: "2.9.6"),
            URLQueryItem(name: "clienttype", value: "25"),
            URLQueryItem(name: "shorturl", value: info.surl),
            URLQueryItem(name: "dir", value: dir),
            URLQueryItem(name: "root", value: "1"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "num", value: "100"),
            URLQueryItem(name: "order", value: "time"),
            URLQueryItem(name: "desc", value: "1")
        ]
        
        if !info.pwd.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "pwd", value: info.pwd))
        }
        
        var request = URLRequest(url: components.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.networkError(NSError(domain: "", code: -1)) }
            guard http.statusCode == 200 else { throw APIError.httpError(http.statusCode) }
            
            let rawStr = String(data: data.prefix(500), encoding: .utf8) ?? ""
            print("[PanCloud] wxlist response: \(rawStr)")
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errno = json?["errno"] as? Int ?? -1
            
            guard errno == 0 else {
                throw APIError.parseFailed("errno=\(errno), raw=\(rawStr)")
            }
            
            var fileList: [[String: Any]]? = nil
            if let dataObj = json?["data"] as? [String: Any] {
                fileList = dataObj["list"] as? [[String: Any]]
            }
            if fileList == nil {
                fileList = json?["list"] as? [[String: Any]]
            }
            
            guard let list = fileList else {
                throw APIError.parseFailed("找不到文件列表, raw=\(rawStr)")
            }
            
            let jsonData = try JSONSerialization.data(withJSONObject: list)
            return try JSONDecoder().decode([PanFile].self, from: jsonData)
        } catch let err as APIError {
            throw err
        } catch {
            throw APIError.networkError(error)
        }
    }
    
    /// 重新获取文件直链（dlink 过期时使用）
    func refreshDlink(info: ShareInfo, cookie: String, dir: String, fileName: String) async throws -> String? {
        let files = try await listFiles(info: info, cookie: cookie, dir: dir)
        return files.first(where: { $0.serverFilename == fileName && $0.isDir != 1 })?.dlink
    }

    func downloadFile(url: URL, cookie: String, to dest: URL) async throws {
        // 重名时先移除旧文件，避免 moveItem 报错
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }

        // dlink 过期/失败时重试（最多3次）
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: url)
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

                let (tempURL, response) = try await session.download(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw APIError.httpError(http.statusCode)
                }
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 等2秒再试
                }
            }
        }
        throw lastError ?? APIError.parseFailed("下载失败")
    }
}

