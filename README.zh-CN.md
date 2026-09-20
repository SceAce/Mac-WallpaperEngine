# Vivid for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

面向 **Apple Silicon（M 系列）、macOS 26+** 的 Wallpaper Engine 播放器。
本仓库基于 [ayasa520/Vivid](https://github.com/ayasa520/Vivid)，维护 macOS 原生应用、
Vivid scene 兼容核心、原 WebUI 和 CEF JavaScript bridge。

- Scene：原 C++ 渲染器，使用 MoltenVK、IOSurface 与 Metal。
- Video：AVFoundation 原生视频播放与循环。
- Web：内置 CEF，支持壁纸属性和鼠标交互。
- 面板：壁纸库、逐屏选择、播放设置和自动轮换。

## 构建与运行

```sh
git clone --recurse-submodules https://github.com/SceAce/Mac-WallpaperEngine.git
cd Mac-WallpaperEngine
brew install cmake ninja pkgconf lz4 pango fontconfig freetype libffi python
bash macos/setup-scene.sh
bash macos/setup-web.sh
bash macos/build-scene.sh
open macos/.build/Vivid.app
```

需要 Swift 6.1+。准备脚本默认通过 `http://127.0.0.1:7897` 下载依赖，
可使用 `VIVID_PROXY` 配置代理。面板地址为 `http://127.0.0.1:8765/`。
首次使用需设置壁纸库及 Wallpaper Engine 原始 `assets` 路径；两者都可以放在本机硬盘，
独立视频壁纸无需 assets。

完整操作见 [macOS 构建、播放和自启动指南](macos/README.zh-CN.md)。
**目前为开发包，仍有外部运行时依赖，使用临时签名，CEF 沙箱尚未启用；独立分发与公证待完成。**
兼容范围与实测限制见 [面板验证](docs/macos-panel-validation.zh-CN.md) 和
[scene 验证](docs/macos-scene-validation.zh-CN.md)。

## 仓库结构

- `macos/`：原生应用、scene/web XPC 服务、WebUI、JS bridge、构建脚本与测试。
- `producer/third_party/`：scene 核心与六个固定版本依赖子模块。保留历史路径，
  避免影响现有子模块与 DXC 构建目录；这里已没有 Linux producer 程序。
- `docs/`：架构决策、源码来源及 macOS 验证记录。

已移除 Linux 桌面客户端、daemon、打包脚本和发行工作流。Linux 用户请使用
[上游 Vivid](https://github.com/ayasa520/Vivid)。第三方依赖内部的跨平台源码保持固定版本原样，
不因此提供 Linux 应用构建入口。详见 [macOS 专用清理记录](docs/macos-only-cleanup.zh-CN.md)。

## 许可证与致谢

采用 [GPL-2.0](LICENSE)，保留 Vivid 的原有兼容实现、
[scene 来源记录](producer/third_party/wallpaper-scene-renderer/PROVENANCE.md) 及第三方许可证。
感谢上游 Vivid、wallpaper-scene-renderer 和 [waywallen](https://github.com/waywallen)。
壁纸和 Wallpaper Engine 原始 assets 由用户自行提供，不随应用重新分发。
