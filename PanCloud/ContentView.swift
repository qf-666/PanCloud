import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var shareLink = ""
    @State private var pwd = ""
    @State private var files: [PanFile] = []
    @State private var xieFiles: [XieFileItem] = []
    @State private var isLoading = false
    @State private var message = ""
    @State private var showWebView = false
    
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
                        if file.isDir != 1, let dlink = file.dlink {
                            Button(action: { downloadDirect(dlink: dlink, name: file.serverFilename) }) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            } else {
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
                    }
                }
                .listStyle(.plain)
            }
        }
    }
    
    private func parseDirect() {
        isLoading = true
        message = ""
        Task {
            do {
                guard let info = BaiduPanAPI.shared.parseShareLink(shareLink) else { await MainActor.run { self.isLoading = false; self.message = "❌ 无法解析分享链接" }; return }
                let result = try await BaiduPanAPI.shared.listFiles(info: info, cookie: settings.cookieString)
                await MainActor.run {
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
    
    private func downloadDirect(dlink: String, name: String) {
        message = "⬇️ 正在下载 \(name)..."
        Task {
            do {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dest = docs.appendingPathComponent(name)
                try await BaiduPanAPI.shared.downloadFile(url: URL(string: dlink)!, cookie: settings.cookieString, to: dest)
                await MainActor.run { self.message = "✅ 已保存: \(name)" }
            } catch {
                await MainActor.run { self.message = "❌ 下载失败: \(error.localizedDescription)" }
            }
        }
    }
    
    private func parseXieyun() {
        isLoading = true
        message = ""
        Task {
            do {
                let list = try await XiecloudAPI.shared.parseAndList(url: shareLink, pwd: pwd)
                await MainActor.run {
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
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

