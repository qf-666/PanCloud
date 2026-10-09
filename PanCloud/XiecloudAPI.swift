import Foundation

struct XieParseResult: Codable {
    let surl: String?
    let shareid: String?
    let uk: String?
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
    private let accessToken = "WBA9VqwS"
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
    
    func parse(url: String, pwd: String = "") async throws -> XieParseResult {
        let req = makeRequest(path: "/api/parse", body: ["url": url, "pwd": pwd])
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(XieParseResult.self, from: data)
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