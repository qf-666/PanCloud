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
    private static let UA_WEB = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    
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
        // 4. 正则兜底：找独立的4位字母数字串
        if pwd.isEmpty {
            let nsStr = link as NSString
            if let regex = try? NSRegularExpression(pattern: "(?:^|\\s|[:：=])([a-zA-Z0-9]{4})(?:\\s|$|[^a-zA-Z0-9])", options: []) {
                let matches = regex.matches(in: link, options: [], range: NSRange(location: 0, length: nsStr.length))
                if let lastMatch = matches.last {
                    let codeRange = lastMatch.range(at: 1)
                    if codeRange.location != NSNotFound {
                        pwd = nsStr.substring(with: codeRange)
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
    
    /// RC4 — 百度 sign2 下发的 JS 本质就是 RC4(key=sign3, data=sign1)
    private func rc4(key: String, data: String) -> Data {
        let k = Array(key.utf8)
        var s = Array(0...255)
        var j = 0
        for i in 0...255 {
            j = (j + s[i] + k[i % k.count]) % 256
            s.swapAt(i, j)
        }
        var out = Data()
        var i = 0, jj = 0
        for byte in data.utf8 {
            i = (i + 1) % 256
            jj = (jj + s[i]) % 256
            s.swapAt(i, jj)
            let k = s[(s[i] + s[jj]) % 256]
            out.append(byte ^ k)
        }
        return out
    }

    /// 实时取 bdstoken
    func bdstoken(cookie: String) async throws -> String {
        let comps = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
        comps.queryItems = [
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "fields", value: #"["bdstoken"]"#)
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(UA_WEB, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, _) = try await session.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (j?["errno"] as? Int) == 0, let bdstoken = (j?["result"] as? [String: Any])?["bdstoken"] as? String else {
            throw APIError.parseFailed("bdstoken 取失败")
        }
        return bdstoken
    }

    /// 实时取 sign (600s 过期)
    func sign(cookie: String) async throws -> (sign: String, timestamp: Int64) {
        let comps = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
        comps.queryItems = [
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "fields", value: #"["sign1","sign2","sign3","timestamp"]"#)
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(UA_WEB, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, _) = try await session.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (j?["errno"] as? Int) == 0, let r = j?["result"] as? [String: Any],
              let sign1 = r["sign1"] as? String, let sign3 = r["sign3"] as? String,
              let timestamp = r["timestamp"] as? Int64 else {
            throw APIError.parseFailed("sign 取失败")
        }
        let signed = rc4(key: sign3, data: sign1)
        return (signed.base64EncodedString(), timestamp)
    }

    /// 自己网盘零转存直链 (vip=2)
    func dlinkSelf(fsIds: [String], cookie: String) async throws -> [String] {
        let (sig, ts) = try await sign(cookie: cookie)
        let bdstoken = try await bdstoken(cookie: cookie)
        var comps = URLComponents(string: "https://pan.baidu.com/api/download")!
        comps.queryItems = [
            URLQueryItem(name: "sign", value: sig),
            URLQueryItem(name: "timestamp", value: String(ts)),
            URLQueryItem(name: "bdstoken", value: bdstoken),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "type", value: "dlink")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(UA_WEB, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fidlist = fsIds.map { "\"\($0)\"" }.joined(separator: ",")
        let body = "fidlist=[\(fidlist)]&type=dlink&vip=2"
        req.httpBody = body.data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (j?["errno"] as? Int) == 0, let dlinks = j?["dlink"] as? [[String: Any]] else {
            throw APIError.parseFailed("dlink 解析失败: \(j ?? [:])")
        }
        return dlinks.compactMap { $0["dlink"] as? String }
    }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        
        let (tempURL, _) = try await session.download(for: request)
        try FileManager.default.moveItem(at: tempURL, to: dest)
    }
}

