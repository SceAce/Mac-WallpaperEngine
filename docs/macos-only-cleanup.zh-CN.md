# macOS 专用仓库清理（2026-09-20）

目标：移除本仓库不再维护的 Linux 应用与构建入口，保留 macOS 当前的播放和配置行为。
不重新实现兼容算法，不修改固定版本依赖源码，不改写用户壁纸与 assets。

## 删除范围

- `consumer/`：GNOME 扩展、KDE 插件、Wayland layer-shell 客户端及其安装示例。
- 原 `producer/src/` 的 Linux daemon、GPU/DRM 枚举、renderer host、scene/video/web Linux 入口。
- 原 Linux 二进制 display/renderer 协议、生成工具、WebUI socket 传输及生成的 Python 绑定。
- `tools/`、Flatpak manifest/launcher、Linux desktop/metainfo 文件、Linux Release 工作流。
- scene 的 Linux DMA-BUF 导出、GStreamer 视频缓存，以及未使用的 Qt/OpenGL 示例、GL loader、
  Linux RenderDoc 调试钩子和对应 CMake 分支。
- 已无调用者的 Linux 协议说明与旧迁移文档；历史内容仍可通过 Git 查看。

## 保留与移动

| 内容 | 当前位置与原因 |
| --- | --- |
| 原生宿主、播放器、XPC 和测试 | `macos/`，保留已有窗口、设置、播放事务和帧租约 |
| 原 WebUI | `macos/WebUI/`，保留界面、目录解析、用户属性与 HTTP API |
| CEF JS bridge | `macos/Web/vivid_web_bridge_js.h`，仅移动，内容与清理前一致 |
| 原图标 | `macos/Resources/vivid.svg`，保留项目视觉资源 |
| scene 核心 | `producer/third_party/wallpaper-scene-renderer/`，保留解析、脚本、粒子、文字、特效与渲染图 |
| 六个依赖子模块 | 路径、远程和提交号不变，保留其内部跨平台源码与许可证 |
| 许可证与来源 | 根 LICENSE、scene LICENSE/PROVENANCE 和依赖声明保留 |

保留 `producer/third_party` 的历史路径是为了兼容已有子模块和 DXC 编译目录，
不是保留 Linux producer。macOS scene 构建直接选择 IOSurface/AVFoundation 后端。
本轮没有改动 scene 的兼容算法；VulkanRender 只删除未启用的 RenderDoc 钩子并更新注释。

WebUI 后端现在只通过继承的 JSON 行管道联系原生应用，不再接收 `--socket` 或 `--native-stdio`。
控制编号、配置字段、HTTP 路由与项目解释保持原值，默认端口仍为 8765。
详细消息契约见 [WebUI 契约](../macos/WebUI/CONTRACT.md)。
构建时替换生成的面板资源目录，避免旧协议模块残留；Python 使用 `-B`，
防止运行时写入 `__pycache__` 破坏应用包签名。

## 验证

环境：Apple M1 Pro、macOS 26.6.2，使用本地壁纸库及本地 `assets`。
测试应用使用隔离配置和临时面板端口，未修改正常使用的壁纸设置。

- 完整开发包构建通过，Swift 将警告视为错误；JS/Python/shell 语法和 Git 空白检查通过。
- Swift 项目解析测试 3/3，scene CTest 2/2。
- 真实 WebKit 窗口加载面板：55 个项目，中文设置与能力过滤正常。
- 16/16 视频首帧与播放时间检查通过；面板切换 video/scene、暂停恢复、设置更新通过。
- 无效路径、非法设置、损坏 MP4 的回退检查通过，旧壁纸与保存配置保持正常。
- scene `2902406982`、`3220055919`、`3265672285` 共 3/3 通过；每项 100 帧，
  检查画面、动画、alpha、三槽背压、暂停恢复与停止。
- CEF 自有测试页 100 帧通过，包含实时属性、鼠标交互、画面变化、背压、暂停恢复与停止。
- 不同来源的 HTTP 请求仍返回 403；隔离应用退出后，Python 后端监听端口关闭。
- 新包运行前后均通过 `codesign --verify --deep --strict`，无 Python 缓存写入包内。
- 构建图不再引用已删除的 Linux/Qt/GL 后端，打包资源与当前源码一致，JS bridge 内容保持一致。

本地日志位于被 Git 忽略的 `macos/.build/`：`macos-only-build.log`、`macos-only-swift-tests.log`，
以及 `verification/macos-only-{panel,browser,web,scenes}.log`。

本轮没有新增平台兼容性承诺：只复测三个代表性 scene；Web 使用自有测试页；
多台物理显示器未验收。仍为依赖本机运行库的开发包，发行签名、公证、CEF 沙箱及独立分发尚待完成。
源码清理不会直接降低运行时内存，已删除的 Linux 程序本来就没有在 macOS 上运行。
