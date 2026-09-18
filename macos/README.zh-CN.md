# Vivid macOS

[English](README.md) | [简体中文](README.zh-CN.md)

面向 Apple Silicon、macOS 26+ 的开发版壁纸播放器，构建需要 Swift 6.1+。
真实 Wallpaper Engine scene 项目由已恢复的 Vivid C++ 渲染核心运行。
Vulkan/MoltenVK 将画面渲染到 IOSurface，XPC 服务将已完成的帧传递给原生 Metal 桌面显示层。
SceneScript、特效、粒子、绳索、文字和内嵌视频均复用原有 scene 渲染流程。
已测试的素材与剩余兼容性限制见 [验证记录](../docs/macos-scene-validation.zh-CN.md)。

## 构建

先按 [第三方依赖说明](../producer/third_party/README.md) 恢复固定版本的递归子模块，
再在项目根目录执行以下命令。本文后续命令也以项目根目录为工作目录。

```sh
brew install cmake ninja pkgconf lz4 pango fontconfig freetype libffi
bash macos/setup-scene.sh
bash macos/build-scene.sh
```

准备脚本默认通过代理 `http://127.0.0.1:7897` 下载 MoltenVK 1.4.2 并验证校验值，
同时构建固定版本的 arm64 DXC。可通过环境变量 `VIVID_PROXY` 修改代理地址。
构建过程不会改写依赖源码。应用生成在 `macos/.build/Vivid.app`，使用临时签名（ad hoc）。
**当前开发版依赖本机外部的 Homebrew、DXC 和 MoltenVK 库，尚不是可独立分发、已完成公证的发行版。**

## 播放 scene 壁纸

需要同时提供壁纸项目目录和 Wallpaper Engine 原始安装中的 `assets` 目录。
创意工坊项目通常不包含公共 shader。程序只读取用户文件，不修改原始素材，也不打包或重新分发这些资源。

```sh
macos/.build/Vivid.app/Contents/MacOS/vivid-macos \
  --scene /Users/scemac/Pictures/Wallpapers/WallpaperEngine/3220055919 \
  --assets /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

通过菜单栏图标可暂停、恢复播放或退出。添加 `--mute` 可关闭 scene 声音；默认仅主显示器播放声音。
系统音频采集、频谱输入和系统媒体集成尚未接入。
鼠标位置和左键状态以 30 Hz 采样，窗口不会抢占 Finder 的点击。
目前鼠标位于前台窗口上方时也会更新输入，仅响应桌面点击的精确路由仍需完善和验收。

scene 按显示器实际像素分辨率渲染，目标为 30 FPS。
播放器通过 GPU 纹理复制和数量受限的帧租约传递画面，播放过程中不把帧读回 CPU。
shader、纹理缓存及渲染日志位于 `~/Library/Caches/org.sceace.vivid/scene/`。

添加 `--probe-duration 30` 可执行 30 秒桌面播放检查。
`--image <file>` 和 `--diagnostic-color <r> <g> <b>` 仍使用独立的 P0 诊断渲染器。
播放 scene 时请启动上述应用包内的可执行文件；单独的 SwiftPM 可执行文件不包含 XPC 服务。

## 验证

```sh
ctest --test-dir macos/.build/scene --output-on-failure
macos/.build/debug/vivid-macos-selftest macos/.build/verification
macos/.build/VividSceneTest.app/Contents/MacOS/vivid-macos \
  /Users/scemac/Pictures/Wallpapers/WallpaperEngine/3220055919 \
  /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets \
  macos/.build/verification/rope
python3 macos/test-scenes.py \
  /Users/scemac/Pictures/Wallpapers/WallpaperEngine \
  /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

scene 自检使用真实 XPC 服务，并通过 Metal 回读图像进行检查。
它采样第 1、45、90 帧，检查图像细节、不透明覆盖和画面变化；
同时持有全部三个帧租约以检查背压，验证暂停与恢复，发送鼠标位置和按键输入，并检查停止后的行为。
FPS 统计扣除了 PNG 截图和主动暂停的时间。
批量测试将 `results.json`、各壁纸的 PNG 和日志写入 `macos/.build/verification/matrix`。
如果素材本身静止或仅随音频变化，动画检查可能失败，应结合素材分析原因，不能通过降低检查标准掩盖问题。
这些测试验证播放行为，不代表画面已经与 Windows 原版逐像素一致。

GPU、XPC 和桌面检查需要在已登录的图形会话中运行。
独立的项目测试覆盖属性类型和项目路径；原核心的 `scene_identity` 测试覆盖共享场景身份逻辑。
较早的 [帧传输探针](Probes/FrameTransport) 还测试了格式错误或过期的消息，以及生产进程退出，
但它与实际 scene 服务是独立的实现。

开发时遵循 [开发规范](DEVELOPMENT.md) 和 [scene 接口契约](Scene/CONTRACT.md)。
scene 核心及其 macOS 修改由本仓库直接管理，位于 `producer/third_party/wallpaper-scene-renderer/`。
推送本仓库即可同时发布核心和应用代码。其中的第三方库仍是固定版本的子模块，按前面的说明恢复即可。
本项目不使用构建时修改依赖源码的补丁脚本。
