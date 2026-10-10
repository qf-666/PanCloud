import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // 系统在后台下载事件到达时唤醒 App：暂存 completionHandler，
        // 等 URLSession 的 urlSessionDidFinishEvents 回调时再调用
        UIApplication.shared.backgroundCompletionHandler = completionHandler
        _ = DownloadManager.shared   // 触发 session 创建，接管事件
    }
}

@main
struct PanCloudApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
    }
}
