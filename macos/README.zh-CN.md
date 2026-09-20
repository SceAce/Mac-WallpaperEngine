# Vivid macOS

[English](README.md) | [简体中文](README.zh-CN.md)

面向 Apple Silicon、macOS 26+ 的开发版 Wallpaper Engine 播放器。保留 Vivid 的 WebUI 和 scene 核心，
使用 macOS 原生桌面窗口。应用会自动启动面板后端并打开浏览器，本仓库仅维护 macOS。面板源码位于 `macos/WebUI`。

## 构建

先按 [第三方依赖说明](../producer/third_party/README.md) 恢复固定版本的递归子模块，再在仓库根目录运行：

```sh
brew install cmake ninja pkgconf lz4 pango fontconfig freetype libffi python
bash macos/setup-scene.sh
bash macos/setup-web.sh
bash macos/build-scene.sh
```

需要 Swift 6.1+。准备脚本通过 `http://127.0.0.1:7897` 代理下载并校验固定版本的 MoltenVK / CEF；
可用 `VIVID_PROXY` 指定代理。构建不会修改依赖源码。CEF 使用 ARM64 144.0.35，包含原有 JS bridge。

应用位于 `macos/.build/Vivid.app`，使用临时签名。**这是开发版：仍依赖本机 Python、Homebrew、DXC 和
MoltenVK；CEF 子进程暂未启用 Chromium 沙箱，尚未完成独立分发、发行签名和公证。**

## 启动面板

首次运行建议明确指定壁纸库和公共资源：

```sh
macos/.build/Vivid.app/Contents/MacOS/vivid-macos \
  --library /Users/scemac/Pictures/Wallpapers/WallpaperEngine \
  --assets /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

之后双击 `Vivid.app` 即可恢复保存的配置。面板默认地址为 `http://127.0.0.1:8765`，
也可从菜单栏选择“打开壁纸面板”。如需修改端口，可在应用启动环境中设置 `VIVID_WEBUI_PORT`；
端口被占用时，后端会报告启动错误。应用退出时关闭面板后端。
`--no-panel` 只禁止自动打开浏览器，后端仍可通过菜单栏访问。

面板可浏览、搜索、筛选和排序壁纸，按显示器选择/移除项目，编辑并保存用户属性；
支持播放/暂停、全局及逐屏静音、音量、缩放和自动轮换。默认仅主屏播放声音，其他屏可独立取消静音。
支持独立显示器模式，暂不提供跨屏共享渲染的复制模式。
未接入的 GPU 选择、应用匹配规则及自动播放策略不会显示为可用设置。

配置保存在 `~/Library/Application Support/org.sceace.vivid/config.json`，原子写入。
测试可通过 `--config <文件>` 使用隔离配置。切换项目时先等待新播放器首帧，再替换旧窗口；
路径不存在、格式不支持或加载失败时，保留旧壁纸，面板会报告错误并允许重新选择。

## 壁纸类型

- **Scene**：Vivid C++ 核心 → Vulkan/MoltenVK → 三缓冲 IOSurface → XPC → Metal。
  复用 SceneScript、粒子、绳索、文字、特效及内嵌视频。支持运行中更新属性、静音、音量、适配方式和帧率。
- **Video**：AVQueuePlayer / AVPlayerLooper / AVPlayerLayer，按媒体时钟解码和循环。
  支持中文文件名、暂停恢复、音量、覆盖/适配/拉伸。格式覆盖以 AVFoundation 能解码的内容为准。
- **Web**：CEF XPC 服务使用加速 IOSurface 输出，共用帧传输与桌面呈现。
  在页面脚本前注入原 Vivid bridge，支持用户属性、暂停通知、鼠标位置与左键。
  CEF 的帧率上限为 60 FPS，scene 可设 5–240 FPS；视频维持媒体帧率。
  网页按屏幕尺寸布局，缩放选项作用于 scene 和 video。
- **预设**：解析 `dependency` 和 `preset`，在同级目录查找基础项目，应用预设属性；
  文件属性相对于预设目录解析，空值保留，循环依赖会被拒绝。

系统音频采集、频谱和系统媒体信息尚未接入。Web 的静音作用于整个浏览器，音量会通知页面并更新 HTML
音视频元素；作者自行建立的 WebAudio 混音仍需页面响应音量通知。原库没有 Web 样本，当前 Web 验证使用
仓库自有测试页，不能据此声称全部创意工坊网页兼容。鼠标采样目前也会收到前台窗口上的位置/左键状态，
桌面窗口本身不截获 Finder 点击。

## 命令行直接播放

使用统一的 `--project`，应用读取 `project.json` 自动分流。旧 `--scene` 参数保留为兼容入口，也会自动识别类型。

```sh
# 视频，无需 assets
macos/.build/Vivid.app/Contents/MacOS/vivid-macos \
  --project /Users/scemac/Pictures/Wallpapers/WallpaperEngine/2519042412

# Scene，需要原始安装目录中的公共资源
macos/.build/Vivid.app/Contents/MacOS/vivid-macos \
  --project /Users/scemac/Pictures/Wallpapers/WallpaperEngine/3265672285 \
  --assets /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

`2519042412` 的入口是 `18.mp4`，属于视频；本地存在的云霄项目 ID 是 **3265672285**，不是 `3265572285`。
`assets` 通常不在壁纸备份内，至少应包含 `shaders/common.h`。外接盘重挂载后路径可能变化，可在设置中修正。
用户壁纸和原始 assets 只读，不修改、不打包重新分发。

`--mute` 在启动时静音。`--probe-duration 5` 在首帧就绪后执行桌面探针，不启动面板、不写用户配置。
`--image`、`--diagnostic-color` 保留为独立的静态诊断源。

## 分发与 GitHub Releases

现在可以发布源码供其他人编译，建议使用带子模块的克隆方式，再按上面的步骤构建：

```sh
git clone --recurse-submodules https://github.com/SceAce/Mac-WallpaperEngine.git
cd Mac-WallpaperEngine
```

GitHub 自动生成的源码压缩包不包含子模块内容。原 Linux 发行工作流已移除，
尚未接入自动构建 macOS `.app` 或 DMG 的发行工作流。

当前生成的 `Vivid.app` 是开发包，还不能作为独立安装包直接分发。scene 可执行文件链接了
Homebrew 动态库，MoltenVK / DXC 的运行时搜索路径也指向本机编译目录；面板依赖外部 Python。
**DMG 只是包装容器，把当前 `.app` 装进去不会消除这些依赖。**

要让其他 M 系列 Mac 用户下载即可运行，发行构建还需要完成：

- 将运行时依赖和相应许可证一起打包，动态库路径改为相对应用包的位置。
- 使用 Release 配置和明确版本号，验证脱离源码目录、未安装开发依赖时的安装和运行。
- 审核 CEF 沙箱和签名配置；使用 Developer ID 签名与 Apple 公证，以提供正常的 Gatekeeper 启动体验。

当前构建脚本尚未完成这些工作。发行包不包含用户壁纸或 Wallpaper Engine 原始 assets，
下载者仍需自行提供素材和公共资源。

## 登录后自动启动

1. 先构建并运行 `Vivid.app`，选择壁纸，保存有效的壁纸库和 assets 路径。
2. 将应用保留在固定位置，例如复制到 `/Applications/Vivid.app`。当前开发包即使复制过去，
   仍需保留原编译目录和已安装依赖；重新构建后，需要重新复制更新的应用。
3. 打开 **系统设置 → 通用 → 登录项与扩展 → 登录时打开**，点击 **＋**，选择 `Vivid.app`。
   取消自启动时，在同一列表移除它。

这是用户登录后的自动启动，应用会恢复保存的壁纸。存放壁纸或 assets 的外接盘需要在启动前挂载。
当前版本启动时也会打开浏览器面板。命令行的 `--no-panel` 可以禁止自动打开面板，
但系统的登录项选择界面不能附加命令行参数。若要静默登录启动，需要配置传入该参数的用户 LaunchAgent，
或后续增加应用内登录启动设置。构建脚本不会自动安装登录项或 LaunchAgent。

## 验证与开发

```sh
swift test --package-path macos
ctest --test-dir macos/.build/scene --output-on-failure
macos/.build/debug/vivid-macos-selftest macos/.build/verification
python3 macos/test-scenes.py \
  /Users/scemac/Pictures/Wallpapers/WallpaperEngine \
  /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

CEF 共用同一帧契约测试程序；在仓库根目录执行：

```sh
VIVID_TEST_SERVICE=org.sceace.vivid.web \
macos/.build/VividSceneTest.app/Contents/MacOS/vivid-macos \
  "$PWD/macos/Tests/Fixtures/web" "$PWD/macos/Tests/Fixtures/web" \
  "$PWD/macos/.build/verification/web"
```

面板端到端测试：先使用 `--no-panel --config "$PWD/macos/.build/verification/panel-config.json" --assets <assets目录>`
启动应用，再以它输出的地址运行 `python3 macos/test-panel.py <地址> <壁纸库> --videos`。
测试会切换壁纸和修改该隔离配置，需要已登录的图形会话。

检查结果和限制见 [面板与多类型验证记录](../docs/macos-panel-validation.zh-CN.md) 及
[原 scene 验证记录](../docs/macos-scene-validation.zh-CN.md)。开发遵循 [开发规范](DEVELOPMENT.md)、
[scene 契约](Scene/CONTRACT.md) 和 [CEF 契约](Web/CONTRACT.md)。scene 核心由本仓库直接管理，外部库保留固定版本子模块。
