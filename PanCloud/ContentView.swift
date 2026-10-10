import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var dl = DownloadManager.shared

    @State private var shareLink = ""
    @State private var pwd = ""

    // 直连
    @State private var files: [PanFile] = []
    @State private var directInfo: ShareInfo?
    @State private var directDir = "/"

    // 协云
    @State private var xieFiles: [XieFileItem] = []
    @State private var xieContext: XiecloudAPI.XieShareContext?
    @State private var xieDir = "/"

    @State private var isLoading = false
    @State private var message = ""
    @State private var showWebView = false
    @State private var shareItem: ShareItem?

    /// 批量选中集合（key = fs_id / fsId）
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

    // MARK: - 顶部分段
    private var modePicker: some View {
        Picker("下载模式", selection: $settings.mode) {
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

    // MARK: - 输入区
    private var directView: some View {
        VStack(spacing: 8) {
            TextField("粘贴完整 Cookie（含 BDUSS）", text: $settings.cookieString, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            linkRow

            Button(action: parseDirect) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    Text("解析文件列表").bold()
                }
                .frame(maxWidth: .infinity).padding(10)
                .background(Color.blue).foregroundColor(.white).cornerRadius(10)
            }
            .disabled(isLoading || settings.cookieString.isEmpty)
        }
    }

    private var xieyunView: some View {
        VStack(spacing: 8) {
            Text("协云模式：调用 pan.xiecloud.cn API，无需 Cookie")
                .font(.caption2).foregroundColor(.secondary)

            linkRow

            HStack(spacing: 10) {
                Button(action: parseXieyun) {
                    HStack {
                        if isLoading { ProgressView().tint(.white) }
                        Text("API 解析").bold()
                    }
                    .frame(maxWidth: .infinity).padding(10)
                    .background(Color.indigo).foregroundColor(.white).cornerRadius(10)
                }
                .disabled(isLoading)

                Button("网页版") { showWebView = true }
                    .frame(width: 84).padding(10)
                    .background(Color.gray.opacity(0.2)).cornerRadius(10)
            }
        }
    }

    private var linkRow: some View {
        HStack(spacing: 8) {
            TextField("分享链接或完整文本", text: $shareLink)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onChange(of: shareLink) { v in
                    let e = XiecloudAPI.extractPassword(from: v)
                    if !e.isEmpty && pwd.isEmpty { pwd = e }
                }
            TextField("提取码", text: $pwd)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
    }

    // MARK: - 批量操作条
    private var toolbar: some View {
        let items = currentKeys
        return Group {
            if !items.isEmpty {
                HStack(spacing: 10) {
                    Button(selection.count == items.count ? "取消全选" : "全选") {
                        if selection.count == items.count { selection.removeAll() }
                        else { selection = Set(items) }
                    }
                    .font(.caption)

                    Spacer()

                    Button {
                        downloadSelected()
                    } label: {
                        Label(selection.isEmpty ? "下载全部" : "下载选中(\(selection.count))",
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

    // MARK: - 文件列表
    private var fileList: some View {
        VStack(spacing: 6) {
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(message.contains("❌") ? .red : .secondary)
            }

            if settings.mode == .direct {
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
                                    onDownload: { downloadDirect(dlink: file.dlink, name: file.serverFilename) })
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if file.isDir == 1 { goDirect(path: file.path) }
                    }
                }
                .listStyle(.plain)
            } else {
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
        }
    }

    /// 行尾：下载中显示进度，否则显示下载按钮；文件夹显示箭头
    @ViewBuilder
    private func rowTrailing(key: String, isDir: Bool, onDownload: @escaping () -> Void) -> some View {
        Group {
            if isDir {
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            } else if let task = dl.tasks.values.first(where: { $0.key == key && ($0.state.isActive || $0.state == .paused || $0.state == .failed) }) {
                rowTrailingForTask(task)
            } else {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
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
                Text("已暂停 \(Int(task.progress * 100))%")
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
                Label("返回上级", systemImage: "arrow.up.left").font(.caption)
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

    // MARK: - 解析 / 浏览
    private func parseDirect() {
        isLoading = true; message = ""; directDir = "/"; selection.removeAll()
        Task {
            do {
                guard var info = BaiduPanAPI.shared.parseShareLink(shareLink) else {
                    await MainActor.run { isLoading = false; message = "❌ 无法解析分享链接" }
                    return
                }
                if !pwd.isEmpty { info = ShareInfo(surl: info.surl, shareId: info.shareId, uk: info.uk, pwd: pwd) }
                let result = try await BaiduPanAPI.shared.listFiles(info: info, cookie: settings.cookieString, dir: "/")
                await MainActor.run {
                    directInfo = info
                    files = result
                    isLoading = false
                    message = "✅ 找到 \(result.count) 项（\(result.filter { $0.isDir == 1 }.count) 个文件夹）"
                }
            } catch {
                await MainActor.run { isLoading = false; message = "❌ \(error.localizedDescription)" }
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
                    message = "✅ \(path) 共 \(result.count) 项"
                }
            } catch {
                await MainActor.run { isLoading = false; message = "❌ \(error.localizedDescription)" }
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
                    if list.isEmpty { message = "⚠️ 解析成功但未找到文件" }
                    else { message = "✅ 解析到 \(list.count) 项（\(list.filter { $0.isdir == 1 }.count) 个文件夹）" }
                }
            } catch {
                await MainActor.run { isLoading = false; message = "❌ \(error.localizedDescription)" }
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
                    message = "✅ \(path) 共 \(list.count) 项"
                }
            } catch {
                await MainActor.run { isLoading = false; message = "❌ \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - 下载
    private func downloadDirect(dlink: String?, name: String) {
        guard let dlink = dlink, let url = URL(string: dlink) else {
            message = "❌ 该文件没有可用下载链接"
            return
        }
        dl.enqueue(
            key: name, fileName: name,
            provider: { url },
            headers: ["Cookie": settings.cookieString,
                      "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"]
        )
        message = "⬇️ 已加入下载队列：\(name)"
    }

    private func downloadXieyun(_ file: XieFileItem) {
        guard let context = xieContext else { message = "❌ 请先解析分享链接"; return }
        dl.enqueue(
            key: file.fs_id, fileName: file.server_filename,
            provider: { try await XiecloudAPI.shared.downloadFile(context: context, file: file) }
        )
        message = "⬇️ 已加入下载队列：\(file.server_filename)"
    }

    /// 批量：选中项 > 全部文件
    private func downloadSelected() {
        if settings.mode == .direct {
            guard let info = directInfo else { return }
            let targets = selection.isEmpty
                ? files.filter { $0.isDir != 1 }
                : files.filter { $0.isDir != 1 && selection.contains(String($0.fsId)) }
            for f in targets {
                let name = f.serverFilename
                let dlink = f.dlink
                dl.enqueue(
                    key: name, fileName: name,
                    provider: {
                        if let d = dlink, let u = URL(string: d) { return u }
                        // 过期重取
                        if let fresh = try await BaiduPanAPI.shared.refreshDlink(
                            info: info, cookie: self.settings.cookieString,
                            dir: self.directDir, fileName: name),
                           let u = URL(string: fresh) { return u }
                        throw APIError.parseFailed("无法获取下载链接")
                    },
                    headers: ["Cookie": settings.cookieString,
                              "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"]
                )
            }
            message = "⬇️ 已加入 \(targets.count) 个下载任务"
        } else {
            guard let context = xieContext else { return }
            let targets = selection.isEmpty
                ? xieFiles.filter { $0.isdir != 1 }
                : xieFiles.filter { $0.isdir != 1 && selection.contains($0.fs_id) }
            for f in targets {
                dl.enqueue(
                    key: f.fs_id, fileName: f.server_filename,
                    provider: { try await XiecloudAPI.shared.downloadFile(context: context, file: f) }
                )
            }
            message = "⬇️ 已加入 \(targets.count) 个下载任务"
        }
    }

    // MARK: - 下载面板
    private var activePanel: some View {
        NavigationStack {
            List {
                if dl.activeTasks.isEmpty {
                    Text("没有正在进行的下载").foregroundColor(.secondary)
                } else {
                    Section {
                        HStack {
                            Text("总进度")
                            Spacer()
                            Text("\(Int(dl.overallProgress * 100))%")
                            Text(DownloadManager.formatSpeed(dl.overallSpeed))
                                .foregroundColor(.secondary)
                        }
                        ProgressView(value: dl.overallProgress)
                        Button(role: .destructive) { dl.cancelAll() } label: { Text("全部取消") }
                    }
                }

                Section("任务") {
                    ForEach(Array(dl.tasks.values).sorted { $0.fileName < $1.fileName }) { task in
                        taskRow(task)
                    }
                }

                Section("已下载") {
                    if dl.finishedFiles.isEmpty {
                        Text("暂无文件").foregroundColor(.secondary)
                    } else {
                        ForEach(dl.finishedFiles, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).font(.subheadline).lineLimit(1)
                                Spacer()
                                Button { shareItem = ShareItem(url: url) } label: { Image(systemName: "square.and.arrow.up") }
                            }
                            .swipeActions {
                                Button(role: .destructive) { dl.delete(url) } label: { Text("删除") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showActivePanel = false }
                }
            }
            .onAppear { dl.refreshFinished() }
        }
    }

    // MARK: - 任务行（面板）
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
                    Label("暂停", systemImage: "pause.fill").font(.caption)
                }
                Button(role: .destructive) { dl.cancel(task.id) } label: {
                    Label("取消", systemImage: "xmark").font(.caption)
                }
            case .paused:
                Button { dl.resume(task.id) } label: {
                    Label("继续", systemImage: "play.fill").font(.caption)
                }
                Button(role: .destructive) { dl.cancel(task.id) } label: {
                    Label("取消", systemImage: "xmark").font(.caption)
                }
            case .failed:
                Button { dl.retry(task.id) } label: {
                    Label("重试", systemImage: "arrow.clockwise").font(.caption)
                }
                Button(role: .destructive) { dl.cancel(task.id) } label: {
                    Label("移除", systemImage: "trash").font(.caption)
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - 分享
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
