# macOS Scene 实现与验证记录

> 本文记录当时的验证结果。后续已移除 Linux 入口与 socket 后端，当前范围见 [macOS 专用清理记录](macos-only-cleanup.zh-CN.md)。

日期：2026-09-18。目标为 Apple Silicon、macOS 26+；实测 Apple M1 Pro、macOS 26.6.2，Swift 6.1.2、AppleClang 17 / CLT SDK 15.5。

原 Vivid scene 核心已能在 macOS 加载真实 Workshop 项目并持续显示到桌面。此次没有引入 Kirie 或 open-wallpaper-engine，也没有在构建脚本中修改依赖源码。本文记录开发版的实测范围，不代表与 Windows Wallpaper Engine 完全一致或已经具备独立发行条件。

## 运行与依赖

构建、启动和测试入口见 [macOS README](../macos/README.md)。当前产物为 `macos/.build/Vivid.app`，需通过 bundle 内可执行文件传入项目和公共 assets 路径：

```sh
macos/.build/Vivid.app/Contents/MacOS/vivid-macos \
  --scene /Users/scemac/Pictures/Wallpapers/WallpaperEngine/3220055919 \
  --assets /Volumes/disk4s2/source/.local/share/Steam/steamapps/common/wallpaper_engine/assets
```

菜单栏支持暂停、恢复和退出；`--mute` 静音，`--probe-duration 30` 限时验证。默认只有主显示器播放 scene 声音。公共 assets 来自已挂载的 Wallpaper Engine 安装目录，Workshop 项目本身通常不含公共 shader、字体和粒子资源；所有原始文件均只读。

scene 核心的上游基线为 `0986aa4e48540eb9ec75786bde88e458ff7dc422`；DXC 使用仓库固定的 `42da79c4...`，MoltenVK 使用 1.4.2 的公开 macOS 分发包。`setup-scene.sh` 验证 MoltenVK 下载校验值，并构建原生 arm64 DXC；默认代理为 `http://127.0.0.1:7897`。

当前 bundle 为开发签名，仍依赖外部 Homebrew、DXC、MoltenVK 路径。根据仓库管理决定，scene 核心及其 macOS 修改已作为普通源码纳入 `producer/third_party/wallpaper-scene-renderer/`，随主仓库一起提交和推送；DXC 等第三方库继续使用固定版本子模块。导入前的本地 scene 快照为 `1fd6e58ee614dad9cae932592bbb7717c2e0726f`，来源与导入校验见 [PROVENANCE.md](../producer/third_party/wallpaper-scene-renderer/PROVENANCE.md)。发行前还需完成依赖打包、签名、公证及干净机测试。

## 平台边界与算法

- C++ 核心继续负责项目解析、SceneScript、仿真、粒子和渲染图；AppKit 负责窗口、显示器和菜单，Metal 负责显示。Linux 的 DMA-BUF / GStreamer 与 macOS 的 IOSurface / AVFoundation 由 CMake 选择，无平台解码头文件反向泄漏到公共接口。
- Vulkan/MoltenVK 导入三张 RGBA IOSurface；Vulkan fence 完成后通过 XPC 发布。消费端复制到私有 Metal 纹理，GPU 完成才归还租约。每个连接拥有自己的会话、generation、slot、sequence，状态为 `Free → Writing → Ready → Free`。三槽查找为 O(3)，队列和共享帧内存有界；超时不授权重用未归还槽位。
- 尺寸变化建立新连接和资源池；旧帧由仍持有它的 Metal 对象管理。服务保留 start 消息到会话结束，以保留 XPC 的客户端优先级捐赠。释放该消息曾使后台定时器降速到约 4–7 FPS；修正消息生命周期后恢复正常。播放活动允许系统睡眠，暂停和退出时结束活动。
- 标准 sprite 使用原 shader 的 `GS_ENABLED=0` 路径和 indexed quad。rope 每个原始段提交一个 instance，使用 `SV_VertexID` 选择端点或 Bezier 细分。原 VS/GS 的宽度、颜色、光照、折射表达式保留，受支持的细分循环被改写为单次选定细分计算，总复杂度 O(段数 × 细分数)，不重复执行整个输出循环。支持细分 0…510，遵守原 GS 的 1024 顶点上限；直接乘法计算 t 与反复相加可能有浮点舍入差异。不认识的几何材质或控制流明确报错。
- 内嵌视频由 AVFoundation 解码到 BGRA IOSurface，再导入 Vulkan 并复制到稳定纹理；包括循环、暂停、seek 状态。压缩载荷仅在加载时写入私有临时文件，不在帧循环写文件。内嵌视频纹理按原解码用途静音。
- Pango 文本显式使用 FreeType/Fontconfig map，字体注册和布局共享后端，避免 macOS 默认 CoreText map 忽略 assets 字体。骨骼解析按段边界读取，允许有骨骼、无 MDLA 动画表的模型；已有动画模型仍走原路径。
- 颜色附件默认加载既有内容，仅在拥有该目标的 pass 明确要求时清空。混合模式不能证明全屏覆盖：局部粒子、discard、只写 RGB 都需要保留未写通道。旧的 `DONT_CARE` 规则在 Apple GPU 上造成块状透明洞和黑块；修复的是 render pass 的数据保留语义，没有更改壁纸或粒子 shader。代价是放弃未经覆盖证明的 discard 优化，可能增加附件加载流量。

完整帧所有权契约见 [Scene/CONTRACT.md](../macos/Scene/CONTRACT.md)。

## 真实素材结果

最终全量报告为 `macos/.build/verification/final-matrix/results.json`，**38/38 通过本轮自动播放检查**。每张保存第 1、45、90 帧 PNG、shader 缓存和日志；预览总图为同目录 `contact-sheet.png`。测试分辨率 960×600，每张接收 100 帧。

检查包括：图像至少 256 种颜色、整帧不透明、第 45/90 帧有像素变化、三槽全部持有时停止生产、释放后恢复、重复客户端 release 幂等、暂停稳定后无新帧、恢复以及停止后无新帧。测试期间发送连续鼠标位置和左键状态。合成输入与鼠标尾迹图像证明输入路径可用，但尚未逐项断言每种脚本的点击回调次数。

| 覆盖项 | 实测项目 ID 与证据 |
| --- | --- |
| 图像、叠加特效、脚本 | `2569317489`、`2884170082`；`2902406982` 含约 140 个对象 |
| sprite / spritetrail | `3031347578` 多粒子层；`3146507587` ember / snow，黑块修复后全帧 alpha=255 |
| rope / ropetrail | `3220055919` 鼠标曲线尾迹、细分 100；`3427824116` ropetrail，均持续出帧 |
| 文本与字体 | `3492627662` 多脚本与字体；全量日志不再出现本轮定位的字体后端错误 |
| 无动画表骨骼 | `3342766749`、`3462491575` 正确读取 2 个骨骼、0 个动画，不再回退成矩形图片 |
| 动画骨骼回归 | `3673734535` 原有动画继续播放 |
| 内嵌 MP4 | `3416436251`、`3470764447` 等真实项目，包含多时段视频纹理 |
| 雨景与附件保留 | `3489118596` 粒子黑块消失；强水波效果保留原参数，视觉等价性仍待原版对照 |

`3313801357` 的背景基本静态，包含按分钟变化的时钟和 64 个音频频谱条。前一轮在分钟内采样时因画面不变失败；本轮跨分钟时变化 145 个像素而通过。**这不证明频谱已工作：系统音频采集尚未接入。** 没有放宽动画阈值以掩盖该限制。

`3489118596` 的水波强度分别为 0.09 与 0.16，第二张原始遮罩覆盖人物和文字大部分区域。已检查解析后的 uniform、生成的 shader 和遮罩，隔离副本去掉水波后变形消失。目前没有原应用的同步参考帧，不能据此宣称效果完全一致；也没有加入针对这一项目的削弱水波逻辑。

本轮 GPU 测试 20.9–23.1 FPS，中位数 21.7；此前未并行 Linux 编译时约 22–24 FPS。统计扣除了 PNG 编码和主动暂停，仍包含自检回调开销，不能作为纯渲染性能基准。桌面使用显示器实际 backing resolution，目标 30 FPS；最终 30 秒单屏测试完成 800 帧，窗口逻辑尺寸 1728×1117。满帧率和功耗还需要独立基准。

## 构建与回归

- macOS C++、Objective-C++、Swift 构建通过；自有 Swift / Objective-C++ 目标严格告警，Swift 6 actor 检查保持启用。
- CTest `scene_project`、原核心 `scene_identity` 均通过。项目测试覆盖路径、属性类型、数组、颜色、条件与无效输入。
- 原 Metal 自检通过：方向、sRGB 中间色、等比缩放及黑边。测试产物位于 `macos/.build/verification/metal-final`。
- 桌面窗口测试检查持续完成 GPU 帧、非 key window、点击穿透、位于 Finder 图标下方；这不代替真实 Finder 点击矩阵。
- 最终静态桌面诊断在 5 秒内完成 1 帧后保持静止并正常退出；scene 30 秒测试完成 800 帧后退出。缺失 assets 的真实 XPC 启动测试立即返回错误，无等待超时。
- Linux 采用 Colima x86_64 / Arch 容器编译共享核心和 `scene_identity_test`，以验证拆分后的 Linux 源文件和依赖仍可构建。该环境没有 GPU，且关闭 DXC，不验证 Linux shader 编译或 GPU 播放。日志位于 `macos/.build/linux-{configure,build}.log`。

最早的静态图和 Metal-to-Metal 共享探针结果另见 [P0 历史记录](macos-p0-validation.zh-CN.md)，不能替代这里的真实 scene 证据。

## 尚未验收的能力

1. 系统音频采集、频谱输入和系统媒体集成。scene 声音可播放，但本轮矩阵静音运行，没有音质或音画同步测量。
2. 桌面输入当前轮询全局鼠标，前台窗口上方也会更新；尚未实现和验收仅桌面左键的精确路由。窗口本身不抢占 Finder 点击。
3. Spaces、Mission Control、Stage Manager、多屏热插拔、睡眠唤醒及长时间资源稳定性；代码中的尺寸重建不等于物理设备矩阵已通过。
4. 任意自定义 geometry shader、未采样的 3D/光照素材与原版逐像素等价性。38 个项目的自动结果是播放证据，不是所有特效无误的证明。
5. 壁纸库 GUI、属性编辑界面、CEF Web 壁纸、独立视频播放器、可脱离开发环境分发的安装包。

本次交付定位为可构建、可用真实素材评估的 scene 桌面播放器，后续按上述能力分别验收。
