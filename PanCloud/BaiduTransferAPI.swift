import Foundation

/// 百度网盘「转存 + 云盘直链」通道，协议逆向自 kuku_pan_dl
/// 流程：分享解析(bdstoken) → 提取码校验 → 转存到自己网盘 → /api/list 拿 fs_id
///      → /api/download(bdstoken+sign) 拿自己文件的 dlink → 多线程 Range 下载
class BaiduTransferAPI {
    static let shared = BaiduTransferAPI()
    private let session: URLSession

    /// 从 kuku_pan_dl 逆向：网盘通道专用 UA
    static let UA_NETDISK = "netdisk;P2SP;2.2.91.136;netdisk;11.42.5;PC;android-android"
    static let UA_WEB = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    private let PAN = "https://pan.baidu.com"
    private let KUKU = "https://kuku.baidu.com"

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpShouldSetCookies = false   // 手动控制 Cookie
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 结果模型

    struct MyFile: Identifiable {
        let fsId: UInt64
        let name: String
        let path: String
        let isDir: Int
        let size: Int64
        var id: String { String(fsId) }
    }

    // MARK: - 底层请求

    private func request(_ urlStr: String,
                         method: String = "GET",
                         query: [String: String] = [:],
                         form: [String: String] = [:],
                         cookie: String,
                         ua: String = BaiduTransferAPI.UA_NETDISK) throws -> URLRequest {
        var comps = URLComponents(string: urlStr)
        if !query.isEmpty {
            let existing = comps?.queryItems ?? []
            comps?.queryItems = existing + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps?.url else { throw BTError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        if method == "POST" {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = form.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&")
            req.httpBody = body.data(using: .utf8)
        }
        return req
    }

    private func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BTError.network }
        let str = String(data: data.prefix(400), encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw BTError.http(http.statusCode, str)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BTError.decode("非 JSON 响应: \(str.prefix(120))")
        }
        return json
    }

    private func errno(_ j: [String: Any]) -> Int {
        (j["errno"] as? Int) ?? (j["errno"] as? String).flatMap { Int($0) } ?? 0
    }

    /// 百度 errno 的常见人话翻译
    private func shareErrnoText(_ e: Int) -> String {
        switch e {
        case -3: return "分享已失效：文件已被删除（来晚啦），转存通道不可用"
        case -9: return "提取码错误"
        case 105: return "链接地址错误"
        case 111: return "需要提取码（请填入提取码后重试）"
        case 116: return "分享内容因违规被屏蔽"
        case 120: return "分享内容因违规被屏蔽"
        case -7: return "分享名称或路径非法"
        default: return "百度网盘错误 \(e)"
        }
    }

    // MARK: - 1. bdstoken

    /// 从分享页 / API 拿 bdstoken（转存必须）
    func getBdstoken(cookie: String) async throws -> String {
        // 方式1: /api/gettemplatevariable
        let req1 = try request("\(PAN)/api/gettemplatevariable",
                               query: ["fields": "[\"bdstoken\"]"],
                               cookie: cookie, ua: Self.UA_WEB)
        if let j = try? await send(req1),
           let result = j["result"] as? [String: Any],
           let token = result["bdstoken"] as? String, !token.isEmpty {
            return token
        }
        // 方式2: 分享页 HTML 里正则
        let req2 = try request("\(PAN)/disk/home", cookie: cookie, ua: Self.UA_WEB)
        let (data, _) = try await session.data(for: req2)
        let html = String(data: data, encoding: .utf8) ?? ""
        if let range = html.range(of: "bdstoken[\"']?\\s*[:=]\\s*[\"']([0-9a-f]{32})", options: String.CompareOptions.regularExpression) {
            let seg = String(html[range])
            if let m = seg.range(of: "[0-9a-f]{32}", options: String.CompareOptions.regularExpression) {
                return String(seg[m])
            }
        }
        throw BTError.noToken
    }

    // MARK: - 2. 提取码校验（返回 BDCLND，写入 session 由服务器 Set-Cookie）

    func verifyPwd(surl: String, pwd: String, cookie: String, bdstoken: String) async throws {
        // 注意：verify 的 surl 要去掉前导 "1"（与 share/list 端点不一致）
        var verifySurl = surl
        if verifySurl.hasPrefix("1") { verifySurl = String(verifySurl.dropFirst()) }
        let req = try request("\(PAN)/share/verify",
                              method: "POST",
                              query: ["surl": verifySurl,
                                      "t": "\(Int(Date().timeIntervalSince1970 * 1000))", "channel": "chunlei", "web": "1", "app_id": "250528", "bdstoken": bdstoken, "clienttype": "0"],
                              form: ["pwd": pwd, "vcode": "", "vcode_str": ""],
                              cookie: cookie)
        _ = try? await send(req)
    }

    // MARK: - 2.5 分享信息（拿 shareid / uk）

    struct ShareMeta { let shareid: String; let uk: String; let fsidList: [String] }

    /// 从分享链接拿 shareid/uk（transfer 必需）
    func shareInfo(surl: String, cookie: String, bdstoken: String) async throws -> ShareMeta {
        let req = try request("\(PAN)/api/shorturlinfo",
                              query: ["shorturl": surl, "bdstoken": bdstoken,
                                      "channel": "chunlei", "web": "1", "app_id": "250528", "clienttype": "0"],
                              cookie: cookie)
        let j = try await send(req)
        let e = errno(j)
        if e != 0 {
            let msg = (j["show_msg"] as? String) ?? (j["err_msg"] as? String) ?? shareErrnoText(e)
            throw BTError.pan(e, msg)
        }
        let shareid = "\(j["shareid"] ?? "")"
        let uk = "\(j["uk"] ?? "")"
        var fsids: [String] = []
        if let list = j["file_list"] as? [[String: Any]] {
            for item in list {
                if let f = item["fs_id"] { fsids.append("\(f)") }
            }
        }
        if shareid.isEmpty || uk.isEmpty { throw BTError.decode("分享信息缺少 shareid/uk") }
        return ShareMeta(shareid: shareid, uk: uk, fsidList: fsids)
    }

    // MARK: - 3. 分享文件列表（root=1 或 shareid/uk/dir）

    func shareList(surl: String, shareid: String, uk: String, dir: String = "/", root: Bool = true, cookie: String, bdstoken: String) async throws -> [[String: Any]] {
        var query: [String: String] = [
            "shorturl": surl,
            "root": root ? "1" : "0",
            "sekey": "",
            "bdstoken": bdstoken,
            "channel": "chunlei",
            "web": "1",
            "app_id": "250528",
            "clienttype": "0"
        ]
        if !root {
            query["shareid"] = shareid
            query["uk"] = uk
            query["dir"] = dir
        }
        let req = try request("\(PAN)/share/list", query: query, cookie: cookie)
        let j = try await send(req)
        if let list = j["list"] as? [[String: Any]] { return list }
        return []
    }

    // MARK: - 4. 转存到自己网盘

    /// 返回转存后的目标路径（默认 /apps/dl/）
    func transfer(shareid: String, uk: String, fsids: [String], dest: String = "/apps/dl", cookie: String, bdstoken: String) async throws -> [String] {
        guard !fsids.isEmpty else { return [] }
        let fsidJSON = "[" + fsids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let req = try request("\(PAN)/share/transfer",
                              method: "POST",
                              query: ["shareid": shareid, "from": uk, "bdstoken": bdstoken,
                                      "channel": "chunlei", "web": "1", "app_id": "250528", "clienttype": "0"],
                              form: ["fsidlist": fsidJSON,
                                     "path": dest,
                                     "async": "1",
                                     "ondup": "newcopy"],
                              cookie: cookie)
        let j = try await send(req)
        let e = errno(j)
        if e != 0 {
            throw BTError.pan(e, (j["err_msg"] as? String) ?? (j["show_msg"] as? String) ?? shareErrnoText(e))
        }
        // 转存结果里返回 extra.list[].to
        var paths: [String] = []
        if let extra = j["extra"] as? [String: Any],
           let list = extra["list"] as? [[String: Any]] {
            for item in list {
                if let to = item["to"] as? String { paths.append(to) }
            }
        }
        return paths
    }

    // MARK: - 5. 列出自己网盘目录（拿 fs_id）

    func myList(dir: String, cookie: String, bdstoken: String) async throws -> [MyFile] {
        let req = try request("\(PAN)/api/list",
                              query: ["dir": dir, "order": "name", "desc": "0", "bdstoken": bdstoken,
                                      "channel": "chunlei", "web": "1", "app_id": "250528", "clienttype": "0"],
                              cookie: cookie)
        let j = try await send(req)
        let e = errno(j)
        if e != 0 { throw BTError.pan(e, (j["err_msg"] as? String) ?? "列目录失败") }
        guard let list = j["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let fsidStr = item["fs_id"].map({ "\($0)" }), let fid = UInt64(fsidStr) else { return nil }
            let name = (item["server_filename"] as? String) ?? ""
            let path = (item["path"] as? String) ?? "\(dir)/\(name)"
            let isdir = (item["isdir"] as? Int) ?? ((item["isdir"] as? String).flatMap { Int($0) } ?? 0)
            let size = (item["size"] as? Int64) ?? ((item["size"] as? String).flatMap { Int64($0) } ?? 0)
            return MyFile(fsId: fid, name: name, path: path, isDir: isdir, size: size)
        }
    }

    // MARK: - 6. 取自己文件的直链（/api/download）

    /// 返回 dlink（自己网盘文件的直链，配合 UA_NETDISK + Cookie 可下载）
    func selfDlink(fsids: [UInt64], cookie: String, bdstoken: String) async throws -> [String] {
        let fsidJSON = "[" + fsids.map { "\($0)" }.joined(separator: ",") + "]"
        let req = try request("\(PAN)/api/download",
                              method: "POST",
                              query: ["bdstoken": bdstoken, "channel": "chunlei", "web": "1",
                                      "app_id": "250528", "clienttype": "0"],
                              form: ["fsidlist": fsidJSON, "type": "dlink"],
                              cookie: cookie)
        let j = try await send(req)
        let e = errno(j)
        if e != 0 { throw BTError.pan(e, (j["err_msg"] as? String) ?? "取直链失败") }
        guard let dlink = j["dlink"] as? [[String: Any]] else { return [] }
        return dlink.compactMap { $0["dlink"] as? String }
    }

    // MARK: - 7. 确保网盘目录存在（转存目标 /apps/dl 等）

    func ensureDir(_ path: String, cookie: String, bdstoken: String) async throws {
        let parts = path.split(separator: "/").map(String.init)
        var cur = ""
        for p in parts {
            cur += "/" + p
            let req = try request("\(PAN)/api/create",
                                  method: "POST",
                                  query: ["bdstoken": bdstoken, "channel": "chunlei", "web": "1",
                                          "app_id": "250528", "clienttype": "0"],
                                  form: ["path": cur, "isdir": "1", "block_list": "[]"],
                                  cookie: cookie)
            _ = try? await send(req)
        }
    }
}

// MARK: - 错误

enum BTError: LocalizedError {
    case badURL
    case network
    case http(Int, String)
    case decode(String)
    case noToken
    case pan(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "URL 构造失败"
        case .network: return "网络错误"
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(80))"
        case .decode(let s): return "解析失败: \(s)"
        case .noToken: return "无法获取 bdstoken，请确认 Cookie 含 BDUSS/STOKEN 且已登录"
        case .pan(let e, let m): return "网盘错误 \(e): \(m)"
        }
    }
}
