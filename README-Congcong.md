# 丛丛影视 iOS

这是基于 `Jstrom2022/tvbox-Swift` 的原生 SwiftUI iOS 工程，应用显示名称为“丛丛影视”。本版本完全移除了 Gateway、雷电模拟器、JAR Bridge 和 Android Worker 依赖。

## 默认配置

首次启动自动加载：

```text
https://ghproxy.net/https://raw.githubusercontent.com/JackEric6/movie/refs/heads/main/movie2_kktvs
```

本配置是标准 `type=1` CMS 源，默认站点为 KKT影视。工程同时保留了本机适配记录：`tvbox/Resources/movie2_kktvs.json`。

## 关于

设置页显示：

```text
Made By 丛丛
```

## 构建 IPA

Windows 无法运行 Xcode，请在 GitHub Actions 中执行 `Build CongcongTV iOS IPA`。工作流会在 macOS runner 上生成：

```text
CongcongTV-unsigned.ipa
```

下载后使用 SideStore 或 AltStore 导入签名安装。需要 iOS 17 或更高版本。

## 本地 macOS 构建

```bash
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project CongcongTV.xcodeproj -scheme CongcongTV -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```
