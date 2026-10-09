import SwiftUI

enum DownloadMode: String, CaseIterable {
    case direct = "直连模式"
    case xieyun = "协云模式"
}

class AppSettings: ObservableObject {
    @Published var mode: DownloadMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    
    @Published var cookieString: String {
        didSet { UserDefaults.standard.set(cookieString, forKey: "cookieString") }
    }
    
    init() {
        let savedMode = UserDefaults.standard.string(forKey: "mode") ?? ""
        self.mode = DownloadMode(rawValue: savedMode) ?? .direct
        self.cookieString = UserDefaults.standard.string(forKey: "cookieString") ?? ""
    }
}