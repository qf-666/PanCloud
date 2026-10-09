# PanCloud

百度网盘下载工具 iOS 版，纯客户端实现，无需后端服务器。

## 两种模式

### 直连模式
- 在 App 内粘贴完整的百度网盘 Cookie（含 BDUSS、STOKEN 等）
- App 直接从 iPhone 本地调用 `pan.baidu.com` API 解析分享链接并获取直链下载
- 不经过任何第三方服务器

### 协云模式
- 直接调用 `pan.xiecloud.cn` API，无需填写 Cookie
- 也可一键打开协云网页版（WKWebView 内嵌）

## 构建

需要 Xcode 15+ / iOS 16+

```bash
xcodebuild -project PanCloud.xcodeproj -scheme PanCloud build
```

或通过 GitHub Actions 自动构建 IPA（推送到 main 分支触发）。

## 项目结构

```
PanCloud/
├── PanCloudApp.swift          # App 入口
├── ContentView.swift          # 主界面
├── AppSettings.swift          # 设置持久化
├── BaiduPanAPI.swift          # 百度直连 API
├── XiecloudAPI.swift          # 协云 API
├── XieyunWebView.swift        # 协云 WebView
└── Info.plist                 # 应用配置
```

</content>