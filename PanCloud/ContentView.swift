import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var dl = DownloadManager.shared

    @State private var shareLink = ""
    @State private var pwd = ""

    // ç´è¿
    @State private var files: [PanFile] = []
    @State private var directInfo: ShareInfo?
    @State private var directDir = "/"

    // åäº
    @State private var xieFiles: [XieFileItem] = []
    @State private var xieContext: XiecloudAPI.XieShareContext?
    @State private var xieDir = "/"

    @State private var isLoading = false
    @State private var message = ""
    @State private var showWebView = false
    @State private var shareItem: ShareItem?

    /// æ¹ééä¸­éåï¼key = fs_id / fsIdï¼
    @State private var selection = Set<String>()
    @State private var showActivePanel = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                modePicker
                if settings.mode == .direct { directView } else { xieyunView }
                toolbar
                fileList
            }
            .padding(.horizontal)
            .navigationTitle("PanCloud")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showActivePanel.toggle()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "arrow.down.circle")
                            if !dl.activeTasks.isEmpty {
                                Text("\(dl.activeTasks.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(3)
                                    .background(Color.red, in: Circle())
                                    .offset(x: 6, y: -6)
                            }
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showWebView) { XieyunWebView() }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
            .sheet(isPresented: $showActivePanel) { activePanel }
        }
    }

    // MARK: - é¡¶é¨åæ®µ
    private var modePicker: some View {
        Picker("ä¸è½½æ¨¡å¼", selection: $settings.mode) {
            ForEach(DownloadMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: settings.mode) { _ in
            selection.removeAll()
            files = []
            xieFiles = []
            message = ""
        }
    }

    // MARK: - è¾å¥åº
    private var directView: some View {
        VStack(spacing: 8) {
            TextField("ç²è´´å®æ´ Cookieï¼å« BDUSSï¼", text: $settings.cookieString, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            linkRow

            Button(action: parseDirect) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    Text("è§£ææä»¶åè¡¨").bold()
                }
                .frame(maxWidth: .infinity).padding(10)
                .background(Color.blue).foregroundColor(.white).cornerRadius(10)
            }
            .disabled(isLoading || settings.cookieString.isEmpty)
        }
    }

    private var xieyunView: some View {
        VStack(spacing: 8) {
            Text("åäºæ¨¡å¼ï¼è°ç¨ pan.xiecloud.cn APIï¼æ é Cookie")
                .font(.caption2).foregroundColor(.secondary)

            linkRow

            HStack(spacing: 10) {
                Button(action: parseXieyun) {
                    HStack {
                        if isLoading { ProgressView().tint(.white) }
                        Text("API è§£æ").bold()
                    }
                    .frame(maxWidth: .infinity).padding(10)
                    .background(Color.indigo).foregroundColor(.white).cornerRadius(10)
                }
                .disabled(isLoading)

                Button("ç½é¡µç") { showWebView = true }
                    .frame(width: 84).padding(10)
                    .background(Color.gray.opacity(0.2)).cornerRadius(10)
            }
        }
    }

    private var linkRow: some View {
        HStack(spacing: 8) {
            TextField("åäº«é¾æ¥æå®æ´ææ¬", text: $shareLink)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onChange(of: shareLink) { v in
                    let e = XiecloudAPI.extractPassword(from: v)
                    if !e.isEmpty && pwd.isEmpty { pwd = e }
                }
            TextField("æåç ", text: $pwd)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
    }

    // MARK: - æ¹éæä½æ¡
    private var toolbar: some View {
        let items = currentKeys
        return Group {
            if !items.isEmpty {
                HStack(spacing: 10) {
                    Button(selection.count == items.count ? "åæ¶å¨é" : "å¨é") {
                        if selection.count == items.count { selection.removeAll() }
                        else { selection = Set(items) }
                    }
                    .font(.caption)

                    Spacer()

                    Button {
                        downloadSelected()
                    } label: {
                        Label(selection.isEmpty ? "ä¸è½½å¨é¨" : "ä¸è½½éä¸­(\(selection.count))",
                              systemImage: "arrow.down.to.line")
                            .font(.caption).bold()
                    }
                    .disabled(activeFileCount(for: items) == 0)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var currentKeys: [String] {
        if settings.mode == .direct {
            return files.filter { $0.isDir != 1 }.map { String($0.fsId) }
        } else {
            return xieFiles.filter { $0.isdir != 1 }.map { $0.fs_id }
        }
    }

    private func activeFileCount(for keys: [String]) -> Int {
        selection.isEmpty ? keys.count : selection.count
    }

    // MARK: - æä»¶åè¡¨
    private var fileList: some View {
        VStack(spacing: 6) {
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(message.contains("â") ? .red : .secondary)
            }
            if settings.mode == .direct {
                directFileList
            } else {
                xieFileList
            }
        }
    }

    @ViewBuilder
    private var directFileList: some View {
        if !files.isEmpty { breadcrumb(path: directDir) { goDirect(path: $0) } }
        List(files) { file in
            HStack(spacing: 10) {
                if file.isDir != 1 {
                    Image(systemName: selection.contains(String(file.fsId)) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(.blue)
                        .onTapGesture { toggle(String(file.fsId)) }
                }
                Image(systemName: file.isDir == 1 ? "folder.fill" : "doc.fill")
                    .foregroundColor(file.isDir == 1 ? .yellow : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.serverFilename).font(.subheadline).lineLimit(1)
                    if file.isDir != 1 {
                        Text(DownloadManager.formatSize(file.size))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                rowTrailing(key: String(file.fsId),
                            isDir: file.isDir == 1,
                            onDownload: { downloadViaTransfer(file) })
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if file.isDir == 1 { goDirect(path: file.path) }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var xieFileList: some View {
        if !xieFiles.isEmpty { breadcrumb(path: xieDir) { goXie(path: $0) } }
        List(xieFiles) { file in
            HStack(spacing: 10) {
                if file.isdir != 1 {
                    Image(systemName: selection.contains(file.fs_id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(.indigo)
                        .onTapGesture { toggle(file.fs_id) }
                }
                Image(systemName: file.isdir == 1 ? "folder.fill" : "doc.fill")
                    .foregroundColor(file.isdir == 1 ? .yellow : .indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.server_filename).font(.subheadline).lineLimit(1)
                    if file.isdir != 1, let sz = file.size {
                        Text(DownloadManager.formatSize(sz))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                rowTrailing(key: file.fs_id,
                            isDir: file.isdir == 1,
                            onDownload: { downloadXieyun(file) })
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if file.isdir == 1 { goXie(path: file.path ?? "/") }
            }
        }
        .listStyle(.plain)
    }

    /// è¡å°¾ï¼ä¸è½½ä¸­æ¾ç¤ºè¿åº¦ï¼å¦åæ¾ç¤ºä¸è½½æé®ï¼æä»¶å¤¹æ¾ç¤ºç®­å¤´
    @ViewBuilder
    private func rowTrailing(key: String, isDir: Bool, onDownload: @escaping () -> Void) -> some View {
        if isDir {
            Image(systemName: "chevron.right").foregroundColor(.secondary)
        } else if let task = dl.rowTask(forKey: key) {
            rowTrailingForTask(task)
        } else {
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func rowTrailingForTask(_ task: DownloadTask) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            switch task.state {
            case .downloading, .queued:
                ProgressView(value: task.progress).frame(width: 64)
                Text("\(Int(task.progress * 100))% \(DownloadManager.formatSpeed(task.speed))")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            case .paused:
                HStack(spacing: 2) {
                    Image(systemName: "pause.circle.fill").foregroundColor(.orange)
                    Button { dl.resume(task.id) } label: {
                        Image(systemName: "play.circle.fill").foregroundColor(.green)
                    }
                }
                Text("å·²æå \(Int(task.progress * 100))%")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            case .failed:
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Button { dl.retry(task.id) } label: {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundColor(.blue)
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private func breadcrumb(path: String, onTap: @escaping (String) -> Void) -> some View {
        HStack {
            Button { onTap(parentPath(path)) } label: {
                Label("è¿åä¸çº§", systemImage: "arrow.up.left").font(.caption)
            }
            .disabled(path == "/" || path.isEmpty)
            Spacer()
            Text(path).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
    }

    private func parentPath(_ p: String) -> String {
        var parts = p.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        return "/" + parts.joined(separator: "/")
    }

    private func toggle(_ key: String) {
        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
    }

    // MARK: - è§£æ / æµè§
    private func parseDirect() {
        isLoading = true; message = ""; directDir = "/"; selection.removeAll()
        Task {
            do {
                guard var info = BaiduPanAPI.shared.parseShareLink(shareLink) else {
                    await MainActor.run { isLoading = false; message = "â æ æ³è§£æåäº«é¾æ¥" }
                    return
                }
                if !pwd.isEmpty { info = ShareInfo(surl: info.surl, shareId: info.shareId, uk: info.uk, pwd: pwd) }
                let result = try await BaiduPanAPI.shared.listFiles(info: info, cookie: settings.cookieString, dir: "/")
                await MainActor.run {
                    directInfo = info
                    files = result
                    isLoading = false
                    message = "â æ¾å° \(result.count) é¡¹ï¼\(result.filter { $0.isDir == 1 }.count) ä¸ªæä»¶å¤¹ï¼"
                }
            } catch {
                await MainActor.run { isLoading = false; message = "â \(error.localizedDescription)" }
            }
        }
    }

    private func goDirect(path: String) {
        guard let info = directInfo else { return }
        isLoading = true; selection.removeAll()
        Task {
            do {
                let result = try await BaiduPanAPI.shared.listFiles(info: info, cookie: settings.cookieString, dir: path)
                await MainActor.run {
                    directDir = path
                    files = result
                    isLoading = false
                    message = "â \(path) å± \(result.count) é¡¹"
                }
            } catch {
                await MainActor.run { isLoading = false; message = "â \(error.localizedDescription)" }
            }
        }
    }

    private func parseXieyun() {
        isLoading = true; message = ""; xieDir = "/"; selection.removeAll()
        Task {
            do {
                let (context, list) = try await XiecloudAPI.shared.parseAndGetContext(url: shareLink, pwd: pwd)
                await MainActor.run {
                    xieContext = context
                    xieFiles = list
                    isLoading = false
                    if list.isEmpty { message = "â ï¸ è§£ææåä½æªæ¾å°æä»¶" }
                    else { message = "â è§£æå° \(list.count) é¡¹ï¼\(list.filter { $0.isdir == 1 }.count) ä¸ªæä»¶å¤¹ï¼" }
                }
            } catch {
                await MainActor.run { isLoading = false; message = "â \(error.localizedDescription)" }
            }
        }
    }

    private func goXie(path: String) {
        guard let context = xieContext else { return }
        isLoading = true; selection.removeAll()
        Task {
            do {
                let list = try await XiecloudAPI.shared.listFiles(
                    surl: context.surl, shareid: context.shareid, uk: context.uk,
                    pwd: context.pwd, dir: path, bare: context.bare)
                await MainActor.run {
                    xieDir = path
                    xieFiles = list
                    isLoading = false
                    message = "â \(path) å± \(list.count) é¡¹"
                }
            } catch {
                await MainActor.run { isLoading = false; message = "â \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - ä¸è½½ï¼ç´è¿ï¼è½¬å­ â èªå·±ç½çåç´é¾ â å¤çº¿ç¨åçï¼
    private func downloadDirect(dlink: String?, name: String) {
        // ä¿çæ§ dlink ç´ä¸ä½ä¸ºååº
        guard let dlink = dlink, let url = URL(string: dlink) else {
            message = "â è¯¥æä»¶æ²¡æå¯ç¨ä¸è½½é¾æ¥"
            return
        }
        dl.enqueueSegmented(
            key: name, fileName: name,
            headers: ["Cookie": settings.cookieString,
                      "User-Agent": BaiduTransferAPI.UA_NETDISK,
                      "Referer": "https://pan.baidu.com/"],
            provider: { url }
        )
        message = "â¬ï¸ å·²å å¥ä¸è½½éåï¼å¤çº¿ç¨ï¼ï¼\(name)"
    }

    /// ç´è¿Â·è½¬å­æµç¨ï¼æä¸ä¸ªåäº«æä»¶è½¬å­å°èªå·±ç½çï¼ååç´é¾å¤çº¿ç¨ä¸è½½
    private func downloadViaTransfer(_ file: PanFile) {
        guard let info = directInfo else { message = "â è¯·åè§£æåäº«é¾æ¥"; return }
        let name = file.serverFilename
        dl.enqueueSegmented(
            key: name, fileName: name,
            headers: ["Cookie": settings.cookieString,
                      "User-Agent": BaiduTransferAPI.UA_NETDISK,
                      "Referer": "https://pan.baidu.com/"],
            provider: {
                let cookie = self.settings.cookieString
                // 0. 零转存 vip=2：文件若已在自己网盘，直接取 dlink（免转存，走 8 线程分片）
                if let vip = try? await BaiduPanAPI.shared.dlinkSelf(fsIds: [String(file.fsId)], cookie: cookie) {
                    if let first = vip.first, let u = URL(string: first) { return u }
                }
                // 兜底：转存路线
                let api = BaiduTransferAPI.shared
                // 1. å bdstoken
                let token = try await api.getBdstoken(cookie: cookie)
                // 2. æ¿çå® shareid/uk
                let meta = try await api.shareInfo(surl: info.surl, cookie: cookie, bdstoken: token)
                // 3. æåç æ ¡éª
                if !info.pwd.isEmpty {
                    try? await api.verifyPwd(surl: info.surl, pwd: info.pwd, cookie: cookie, bdstoken: token)
                }
                // 4. ç¡®ä¿è½¬å­ç®æ ç®å½å­å¨ï¼ç¶åè½¬å­å°èªå·±ç½ç /apps/dl
                try? await api.ensureDir("/apps/dl", cookie: cookie, bdstoken: token)
                let paths = try await api.transfer(shareid: meta.shareid, uk: meta.uk,
                                                   fsids: [String(file.fsId)],
                                                   dest: "/apps/dl", cookie: cookie, bdstoken: token)
                let targetPath = paths.first ?? "/apps/dl/\(name)"
                // 5. ååºèªå·±ç½çç®å½ï¼ä¼åæè·¯å¾å¹éï¼å¶æ¬¡ææä»¶å
                let dir = (targetPath as NSString).deletingLastPathComponent
                let mine = try await api.myList(dir: dir.isEmpty ? "/apps/dl" : dir, cookie: cookie, bdstoken: token)
                guard let mineFile = mine.first(where: { $0.path == targetPath })
                        ?? mine.first(where: { $0.name == name }) else {
                    throw BTError.decode("è½¬å­åæªå¨ç½çæ¾å°æä»¶: \(name)")
                }
                // 6. åèªå·±æä»¶çç´é¾
                let links = try await api.selfDlink(fsids: [mineFile.fsId], cookie: cookie, bdstoken: token)
                guard let first = links.first, let u = URL(string: first) else {
                    throw BTError.decode("æªè·åå°ç´é¾")
                }
                return u
            }
        )
        message = "â¬ï¸ å·²å å¥ä¸è½½éåï¼è½¬å­+å¤çº¿ç¨ï¼ï¼\(name)"
    }

    private func downloadXieyun(_ file: XieFileItem) {
        guard let context = xieContext else { message = "â è¯·åè§£æåäº«é¾æ¥"; return }
        // åäº /dl/ éå¸¦ x-access-tokenï¼å®æµ 403 "ä¸è½½ç¥¨æ®æ æ"ï¼ï¼æ¯æ Range â åçå¤çº¿ç¨
        dl.enqueueSegmented(
            key: file.fs_id, fileName: file.server_filename,
            headers: ["x-access-token": XiecloudAPI.shared.accessToken,
                      "User-Agent": "Mozilla/5.0"],
            provider: { try await XiecloudAPI.shared.downloadFile(context: context, file: file) }
        )
        message = "â¬ï¸ å·²å å¥ä¸è½½éåï¼åäºÂ·å¤çº¿ç¨ï¼ï¼\(file.server_filename)"
    }

    /// æ¹éï¼éä¸­é¡¹ > å¨é¨æä»¶
    private func downloadSelected() {
        if settings.mode == .direct {
            guard let info = directInfo else { return }
            let targets = selection.isEmpty
                ? files.filter { $0.isDir != 1 }
                : files.filter { $0.isDir != 1 && selection.contains(String($0.fsId)) }
            // æ¹éè½¬å­ï¼ä¸æ¬¡è½¬å­å¤ä¸ª fsidï¼åéä¸ªåç´é¾
            Task { @MainActor in
                do {
                    let cookie = settings.cookieString
                    let api = BaiduTransferAPI.shared
                    let token = try await api.getBdstoken(cookie: cookie)
                    let meta = try await api.shareInfo(surl: info.surl, cookie: cookie, bdstoken: token)
                    if !info.pwd.isEmpty {
                        try? await api.verifyPwd(surl: info.surl, pwd: info.pwd, cookie: cookie, bdstoken: token)
                    }
                    let fsids = targets.map { String($0.fsId) }
                    try? await api.ensureDir("/apps/dl", cookie: cookie, bdstoken: token)
                    _ = try await api.transfer(shareid: meta.shareid, uk: meta.uk,
                                               fsids: fsids, dest: "/apps/dl",
                                               cookie: cookie, bdstoken: token)
                    // ä¸æ¬¡æ§ååºè½¬å­ç»æï¼å»ºç« æä»¶å -> fs_id æ å°
                    let mine = try await api.myList(dir: "/apps/dl", cookie: cookie, bdstoken: token)
                    let byName = Dictionary(mine.map { ($0.name, $0.fsId) }, uniquingKeysWith: { a, _ in a })
                    var queued = 0
                    for f in targets {
                        let name = f.serverFilename
                        guard let fsid = byName[name] else { continue }
                        dl.enqueueSegmented(
                            key: name, fileName: name,
                            headers: ["Cookie": cookie,
                                      "User-Agent": BaiduTransferAPI.UA_NETDISK,
                                      "Referer": "https://pan.baidu.com/"],
                            provider: {
                                let links = try await api.selfDlink(fsids: [fsid], cookie: cookie, bdstoken: token)
                                guard let s = links.first, let u = URL(string: s) else { throw BTError.decode("æ ç´é¾") }
                                return u
                            }
                        )
                        queued += 1
                    }
                    message = queued == targets.count
                        ? "â¬ï¸ å·²è½¬å­å¹¶å å¥ \(queued) ä¸ªä¸è½½ä»»å¡"
                        : "â ï¸ è½¬å­ \(targets.count) ä¸ªï¼æåå¹é \(queued) ä¸ªï¼éåæä»¶å¯è½è¢«è·³è¿ï¼"
                } catch {
                    message = "â è½¬å­å¤±è´¥: \(error.localizedDescription)"
                }
            }
        } else {
            guard let context = xieContext else { return }
            let targets = selection.isEmpty
                ? xieFiles.filter { $0.isdir != 1 }
                : xieFiles.filter { $0.isdir != 1 && selection.contains($0.fs_id) }
            for f in targets {
                dl.enqueueSegmented(
                    key: f.fs_id, fileName: f.server_filename,
                    headers: ["x-access-token": XiecloudAPI.shared.accessToken,
                              "User-Agent": "Mozilla/5.0"],
                    provider: { try await XiecloudAPI.shared.downloadFile(context: context, file: f) }
                )
            }
            message = "â¬ï¸ å·²å å¥ \(targets.count) ä¸ªä¸è½½ä»»å¡ï¼åäºÂ·å¤çº¿ç¨ï¼"
        }
    }

    // MARK: - ä¸è½½é¢æ¿
    private var activePanel: some View {
        NavigationStack {
            List {
                if dl.activeTasks.isEmpty {
                    Text("æ²¡ææ­£å¨è¿è¡çä¸è½½").foregroundColor(.secondary)
                } else {
                    Section {
                        HStack {
                            Text("æ»è¿åº¦")
                            Spacer()
                            Text("\(Int(dl.overallProgress * 100))%")
                            Text(DownloadManager.formatSpeed(dl.overallSpeed))
                                .foregroundColor(.secondary)
                        }
                        ProgressView(value: dl.overallProgress)
                        Button(role: .destructive) { dl.cancelAll() } label: { Text("å¨é¨åæ¶") }
                    }
                }

                Section("ä»»å¡") {
                    ForEach(Array(dl.tasks.values).sorted { $0.fileName < $1.fileName }) { task in
                        taskRow(task)
                    }
                }

                Section("å·²ä¸è½½") {
                    if dl.finishedFiles.isEmpty {
                        Text("ææ æä»¶").foregroundColor(.secondary)
                    } else {
                        ForEach(dl.finishedFiles, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).font(.subheadline).lineLimit(1)
                                Spacer()
                                Button { shareItem = ShareItem(url: url) } label: { Image(systemName: "square.and.arrow.up") }
                            }
                            .swipeActions {
                                Button(role: .destructive) { dl.delete(url) } label: { Text("å é¤") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("ä¸è½½")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("å®æ") { showActivePanel = false }
                }
            }
            .onAppear { dl.refreshFinished() }
        }
    }

    // MARK: - ä»»å¡è¡ï¼é¢æ¿ï¼
    @ViewBuilder
    private func taskRow(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.fileName).font(.subheadline).lineLimit(1)
                Spacer()
                Text(task.state.label).font(.caption2).foregroundColor(stateColor(task.state))
            }
            ProgressView(value: task.progress)
            HStack {
                Text(sizeText(task))
                Spacer()
                Text(DownloadManager.formatSpeed(task.speed))
            }
            .font(.system(size: 10)).foregroundColor(.secondary)
            taskActions(task)
        }
        .padding(.vertical, 2)
    }

    private func stateColor(_ state: DownloadState) -> Color {
        switch state {
        case .paused: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    private func sizeText(_ task: DownloadTask) -> String {
        let w = DownloadManager.formatSize(task.writtenBytes)
        let t = DownloadManager.formatSize(task.totalBytes)
        return "\(w) / \(t)"
    }

    @ViewBuilder
    private func taskActions(_ task: DownloadTask) -> some View {
        HStack(spacing: 14) {
            switch task.state {
            case .downloading:
                Button { dl.pause(task.id) } label: {
                    Label("æå", systemImage: "pause.fill").font(.caption)
                }
                Button(role: .destructive) { dl.cancel(task.id) } label: {
                    Label("åæ¶", systemImage: "xmark").font(.caption)
                }
            case .paused:
                Button { dl.resume(task.id) } label: {
                    Label("ç»§ç»­", systemImage: "play.fill").font(.caption)
                }
                Button(role: .destructive) { dl.cancel(task.id) } label: {
                    Label("åæ¶", systemImage: "xmark").font(.caption)
                }
            case .failed:
                Button { dl.retry(task.id) } label: {
                    Label("éè¯", systemImage: "arrow.clockwise").font(.caption)
                }
                Button(role: .destructive) { dl.cancel(task.id) } label: {
                    Label("ç§»é¤", systemImage: "trash").font(.caption)
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - åäº«
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
