# 丛丛影视 iOS

这是基于 [`Jstrom2022/tvbox-Swift`](https://github.com/Jstrom2022/tvbox-Swift) 整理的原生 SwiftUI iOS 应用，显示名称为“丛丛影视”，Bundle ID 为 `com.congcong.tv.ios`。

## 本版本范围

- 只保留 iOS App target，最低系统版本为 iOS 17。
- 默认配置为 `movie2_kktvs`：
  `https://ghproxy.net/https://raw.githubusercontent.com/JackEric6/movie/refs/heads/main/movie2_kktvs`
- 该远程文件仍可能含 Android `127.0.0.1` 本地代理地址；iOS 会将 KKT影视源的 loopback `source` 参数转换为直连 CMS API，不依赖本地 Gateway。
- 关于页显示 `Made By 丛丛`。
- 保留 SwiftUI、SwiftData、AVPlayer 和 VLCKit 播放能力。
- 已移植本地 KKT影视适配逻辑：`vod_play_from`、`vod_play_url`、`$$$` 多线路、`#` 多集、`hxplayer`/`2mplayer` 以及播放器页中的直接媒体地址提取。
- 不依赖 Gateway、雷电模拟器、JAR Bridge、Android Worker 或 `spider.jar`。

## 目录

```text
tvbox/
  Services/KktvsResponseNormalizer.swift  # KKT影视响应和播放线路整理
  Services/SourceService.swift             # 分类、列表、详情、搜索和播放地址请求
  Resources/movie2_kktvs.json              # 本地适配配置样本
  tvboxApp.swift                            # 应用名称、默认配置和入口
project.yml                                 # XcodeGen 工程模板
.github/workflows/build-ios.yml             # macOS 云端构建 IPA
README-Congcong.md                          # 简版说明
```

## GitHub Actions 构建 IPA

Windows 不能运行 Xcode，因此不需要在本机反复编译。本仓库根目录就是 iOS 工程，工作流位于 `.github/workflows/build-ios.yml`。推送代码后：

1. 打开仓库的 **Actions** 页面。
2. 选择 **Build CongcongTV iOS IPA**。
3. 点击 **Run workflow**，等待 macOS runner 完成。
4. 在构建任务底部下载 `CongcongTV-unsigned-ipa` artifact。
5. 解压得到 `CongcongTV-unsigned.ipa`。

工作流会在 macOS runner 上执行 XcodeGen、Xcode 构建和 IPA 打包；本地产物是未签名 IPA，必须经过 SideStore 或 AltStore 使用 Apple ID 签名后才能安装到 iPhone。

## 使用 SideStore 安装

1. 在 iPhone 上先完成 SideStore 的初始安装和 Apple ID 登录，并在 SideStore 中完成设备配对。
2. 将下载的 `CongcongTV-unsigned.ipa` 保存到 iPhone 的“文件”App，或通过 AirDrop、网盘等方式传到手机。
3. 在“文件”App 中点击 IPA，选择“共享”或“打开方式”，发送到 SideStore。
4. 在 SideStore 的 **My Apps** 页面确认安装并等待签名完成。
5. 首次打开时，如果系统提示开发者未受信任，进入“设置 > 通用 > VPN 与设备管理”信任对应 Apple ID。
6. 免费 Apple ID 的侧载签名通常有有效期限制，SideStore 需要按其提示定期刷新应用；刷新时保持 iPhone 与 SideStore 的配对条件可用。

如果 SideStore 无法导入，先确认 IPA 是完整下载的 `CongcongTV-unsigned.ipa`，不要直接把 `Payload` 文件夹导入；同时确认 SideStore 已经可以正常安装一个其他 IPA，再重新导入本应用。

## 本地 macOS 构建

```bash
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild \
  -project CongcongTV.xcodeproj \
  -scheme CongcongTV \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

## 配置说明

`tvbox/Resources/movie2_kktvs.json` 是随 App 打包的本地样本；首次启动默认使用远程 `movie2_kktvs` 地址。用户在设置页手动修改配置后，应用会将修改后的地址保存在本机，下次启动优先使用已保存地址。

本工程只实现标准 CMS JSON/XML 和 KKT影视当前适配，不执行 `type=3` JAR 动态脚本。若远程配置后续增加 JAR 源，应用会将其标记为暂不支持，而不会启动本地 Java 或 Gateway 服务。

## 参考

- 上游工程：`Jstrom2022/tvbox-Swift`
- 本地 Android 适配参考：`apps/AVBox-main/app/src/main/java/com/github/tvbox/osc/server/KktvsCmsParser.java`
- 默认配置：`movie2_kktvs`
