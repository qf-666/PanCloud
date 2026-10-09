import Foundation

struct PanFile: Identifiable, Codable {
    let id: String
    let fsId: UInt64
    let serverFilename: String
    let path: String
    let isDir: Int
    let size: Int64
    let dlink: String?
    
    enum CodingKeys: String, CodingKey {
        case id = "fs_id"
        case fsId = "fs_id"
        case serverFilename = "server_filename"
        case path
        case isDir = "isdir"
        case size
        case dlink
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try c.decode(Int64.self, forKey: .id)
        self.id = String(rawId)
        self.fsId = UInt64(bitPattern: rawId)
        self.serverFilename = try c.decode(String.self, forKey: .serverFilename)
        self.path = try c.decode(String.self, forKey: .path)
        self.isDir = try c.decode(Int.self, forKey: .isDir)
        self.size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
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
        
        if let range = link.range(of: "/s/1") {
            let after = String(link[range.upperBound...])
            let clean = after.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? after
            surl = "1" + clean
        } else if let range = link.range(of: "surl=") {
            let after = String(link[range.upperBound...])
            surl = after.components(separatedBy: "&").first ?? after
        }
        
        if let range = link.range(of: "pwd=") {
            let after = String(link[range.upperBound...])
            pwd = after.components(separatedBy: "&").first ?? after
        } else if let range = link.range(of: "提取码"), range.upperBound < link.endIndex {
            let after = String(link[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            pwd = String(after.prefix(4))
        }
        
        guard !surl.isEmpty else { return nil }
        return ShareInfo(surl: surl, shareId: "", uk: "", pwd: pwd)
    }
    
    func listFiles(info: ShareInfo, cookie: String) async throws -> [PanFile] {
        guard !cookie.isEmpty else { throw APIError.noCookie }
        
        var components = URLComponents(string: "https://pan.baidu.com/share/wxlist")!
        components.queryItems = [
            URLQueryItem(name: "channel", value: "weixin"),
            URLQueryItem(name: "version", value: "2.9.6"),
            URLQueryItem(name: "clienttype", value: "25"),
            URLQueryItem(name: "shorturl", value: info.surl),
            URLQueryItem(name: "dir", value: "/"),
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
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errno = json?["errno"] as? Int ?? -1
            
            if errno == 0, let list = json?["data"] as? [[String: Any]] {
                let jsonData = try JSONSerialization.data(withJSONObject: list)
                return try JSONDecoder().decode([PanFile].self, from: jsonData)
            } else {
                throw APIError.parseFailed("errno=\(errno)")
            }
        } catch let err as APIError {
            throw err
        } catch {
            throw APIError.networkError(error)
        }
    }
    
    func downloadFile(url: URL, cookie: String, to dest: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        
        let (tempURL, _) = try await session.download(for: request)
        try FileManager.default.moveItem(at: tempURL, to: dest)
    }
}

