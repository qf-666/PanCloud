import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var shareLink = ""
    @State private var pwd = ""
    @State private var files: [PanFile] = []
    @State private var xieFiles: [XieFileItem] = []
    @State private var isLoading = false
    @State private var message = ""
    @State private var showWebView = false
    @State private var xieContext: XiecloudAPI.XieShareContext?
    @State private var directInfo: ShareInfo?
    @State private var downloadingId: String?
    @State private var shareItem: ShareItem?
    @State private var directDir = "/"
    @State private var xieDir = "/"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                modePicker
                if settings.mode == .direct { directView } else { xieyunView }
                fileList
                Spacer()
            }
            .padding()
            .navigationTitle("PanCloud")
            .fullScreenCover(isPresented: $showWebView) {
                XieyunWebView()
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private var modePicker: some View {
        Picker("下载模式", selection: $settings.mode) {
            ForEach(DownloadMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var directView: some View {
        VStack(spacing: 12) {
            TextField("粘贴完整 Cookie（含 BDUSS）", text: $settings.cookieString, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            HStack {
                TextField("分享链接", text: $shareLink)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("提取码", text: $pwd)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Button(action: parseDirect) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    Text("解析文件列表").bold()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isLoading || settings.cookieString.isEmpty)
        }
    }

    private var xieyunView: some View {
        VStack(spacing: 12) {
            Text("协云模式：直接调用 pan.xiecloud.cn API，无需填写 Cookie")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                TextField("分享链接", text: $shareLink)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("提取码", text: $pwd)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            HStack(spacing: 12) {
                Button(action: parseXieyun) {
                    HStack {
                        if isLoading { ProgressView().tint(.white) }
                        Text("API 解析").bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.indigo)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isLoading)

                Button("打开网页版") { showWebView = true }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
            }
        }
    }

    private var fileList: some View {
        Group {
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(message.contains("❌") ? .red : .green)
                    .padding(.horizontal)
            }

            if settings.mode == .direct {
                if !files.isEmpty { breadcrumb(path: directDir) { goDirect(path: $0) } }
                List(files) { file in
                    HStack {
                        Image(systemName: file.isDir == 1 ? "folder.fill" : "doc.fill")
                            .foregroundColor(file.isDir == 1 ? .yellow : .blue)
                        VStack(alignment: .leading) {
                            Text(file.serverFilename).font(.subheadline)
                            if file.isDir != 1 {
                                Text(formatSize(file.size)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if file.isDir == 1 {
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        } else if let dlink = file.dlink {
                            Button(action: { downloadDirect(dlink: dlink, name: file.serverFilename) }) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
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
                    HStack {
                        Image(systemName: file.isdir == 1 ? "folder.fill" : "doc.fill")
                            .foregroundColor(file.isdir == 1 ? .yellow : .indigo)
                        VStack(alignment: .leading) {
                            Text(file.server_filename).font(.subheadline)
                            if file.isdir != 1, let sz = file.size {
                                Text(formatSize(sz)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if file.isdir == 1 {
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        } else if downloadingId == file.fs_id {
                            ProgressView()
                        } else {
                            Button(action: { downloadXieyun(file) }) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.indigo)
                            }
                        }
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

    private func breadcrumb(path: String, onTap: @escaping (String) -> Void) -> some View {
        HStack {
            Button {
                onTap(parentPath(path))
            } label: {
                Label("返回上级", systemImage: "arrow.up.left")
                    .font(.caption)
            }
            .disabled(path == "/" || path.isEmpty)
            Spacer()
            Text(path).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.horizontal)
    }

    private func parentPath(_ p: String) -> String {
        var parts = p.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: - 直连模式

    private func parseDirect() {
        isLoading = true
        message = ""
        directDir = "/"
        Task {
            do {
                guard var info = BaiduPanAPI.shared.parseShareLink(shareLink) else {
                    await MainActor.run { self.isLoading = false; self.message = "❌ 无法解析分享链接" }
                    return
                }
                // 输入框里的提取码优先
                if !pwd.isEmpty { info = ShareInfo(surl: info.surl, shareId: info.shareId, uk: info.uk, pwd: pwd) }
                let result = try await BaiduPanAPI.shared.listFiles(info: info, cookie: settings.cookieString, dir: "/")
                await MainActor.run {
                    self.directInfo = info
                    self.files = result
                    self.isLoading = false
                    self.message = "✅ 找到 \(result.count) 个文件"
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.message = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    private func goDirect(path: String) {
        guard let info = directInfo else { return }
        isLoading = true
        Task {
            do {
                let result = try await BaiduPanAPI.shared.listFiles(info: info, cookie: settings.cookieString, dir: path)
                await MainActor.run {
                    self.directDir = path
                    self.files = result
                    self.isLoading = false
                    self.message = "✅ \(path) 共 \(result.count) 项"
                }
            } catch {
                await MainActor.run { self.isLoading = false; self.message = "❌ \(error.localizedDescription)" }
            }
        }
    }

    private func downloadDirect(dlink: String, name: String) {
        message = "⬇️ 正在下载 \(name)..."
        Task {
            do {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dest = docs.appendingPathComponent(name)
                try await BaiduPanAPI.shared.downloadFile(url: URL(string: dlink)!, cookie: settings.cookieString, to: dest)
                await MainActor.run {
                    self.message = "✅ 已保存: \(name)"
                    self.shareItem = ShareItem(url: dest)
                }
            } catch {
                await MainActor.run { self.message = "❌ 下载失败: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - 协云模式

    private func parseXieyun() {
        isLoading = true
        message = ""
        xieDir = "/"
        Task {
            do {
                let (context, list) = try await XiecloudAPI.shared.parseAndGetContext(url: shareLink, pwd: pwd)
                await MainActor.run {
                    self.xieContext = context
                    self.xieFiles = list
                    self.isLoading = false
                    self.message = "✅ 协云解析到 \(list.count) 个文件"
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.message = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    private func goXie(path: String) {
        guard let context = xieContext else { return }
        isLoading = true
        Task {
            do {
                let list = try await XiecloudAPI.shared.listFiles(surl: context.surl, shareid: context.shareid, uk: context.uk, pwd: context.pwd, dir: path)
                await MainActor.run {
                    self.xieDir = path
                    self.xieFiles = list
                    self.isLoading = false
                    self.message = "✅ \(path) 共 \(list.count) 项"
                }
            } catch {
                await MainActor.run { self.isLoading = false; self.message = "❌ \(error.localizedDescription)" }
            }
        }
    }

    private func downloadXieyun(_ file: XieFileItem) {
        guard let context = xieContext else {
            message = "❌ 请先解析分享链接"
            return
        }
        downloadingId = file.fs_id
        message = "⬇️ 正在下载 \(file.server_filename)..."
        Task {
            do {
                let url = try await XiecloudAPI.shared.downloadFile(context: context, file: file)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dest = docs.appendingPathComponent(file.server_filename)
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                await MainActor.run {
                    self.downloadingId = nil
                    self.message = "✅ 已保存: \(file.server_filename)"
                    self.shareItem = ShareItem(url: dest)
                }
            } catch {
                await MainActor.run {
                    self.downloadingId = nil
                    self.message = "❌ 下载失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// 供 sheet 使用的可识别包装
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
