import Foundation

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
}

struct XieListResult: Codable {
    let ok: Bool?
    let list: [XieFileItem]?
}

struct XieFileItem: Identifiable, Codable {
    let fs_id: String
    let server_filename: String
    let isdir: Int
    let size: Int64?
    let path: String?
    
    var id: String { fs_id }
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
    
    /// Step 1: Submit parse task and poll until done
    func parse(url: String, pwd: String = "") async throws -> XieParseResult {
        let req = makeRequest(path: "/api/parse", body: ["url": url, "pwd": pwd])
        
        // Poll up to 30 times (30 seconds max)
        for attempt in 0..<30 {
            let (data, _) = try await session.data(for: req)
            let result = try JSONDecoder().decode(XieParseResult.self, from: data)
            
            if result.done == true || result.partial == false {
                return result
            }
            
            // Not done yet, wait 1 second and retry
            print("[PanCloud] xiecloud parse pending, attempt \(attempt+1), pending=\(result.pending ?? -1)")
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        
        throw NSError(domain: "XiecloudAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "协云解析超时"])
    }
    
    /// Step 2: Fetch file list via new /api/list endpoint
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
        
        let result = try JSONDecoder().decode(XieListResult.self, from: data)
        return result.list ?? []
    }
    
    /// Combined: parse + list
    func parseAndList(url: String, pwd: String = "") async throws -> [XieFileItem] {
        let parseResult = try await parse(url: url, pwd: pwd)
        
        guard let surl = parseResult.surl,
              let shareid = parseResult.shareid,
              let uk = parseResult.uk else {
            throw NSError(domain: "XiecloudAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "协云返回缺少必要字段"])
        }
        
        let actualPwd = parseResult.pwd ?? pwd
        return try await listFiles(surl: surl, shareid: shareid, uk: uk, pwd: actualPwd)
    }
    
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
    
    func pollJob(id: String) async throws -> Bool {
        let req = makeRequest(path: "/api/job?id=\(id)", method: "GET")
        let (data, _) = try await session.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains("done")
    }
    
    func getDLToken(jobId: String) async throws -> URL? {
        let req = makeRequest(path: "/api/dl-token", body: ["jobId": jobId])
        let (data, _) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let urlString = json?["url"] as? String {
            return URL(string: urlString)
        }
        return nil
    }
}
