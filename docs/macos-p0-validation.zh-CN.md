# macOS P0 验证记录

日期：2026-09-18。首版目标已确认：Apple Silicon M 系列、macOS 26+；唯一兼容基线为 Vivid 与 `wallpaper-scene-renderer@0986aa4e...`。

本文保留最初 P0 探针的历史结果，当时尚不能加载 Wallpaper Engine scene。后续已完成原 scene 核心的平台拆分和真实播放链路，当前状态与兼容边界见 [Scene 验证记录](macos-scene-validation.zh-CN.md)。以下“未完成”均指探针阶段，不代表当前实现状态。

## 1. 环境与执行入口

- 实测系统：Apple M1 Pro，macOS 26.6.2，arm64；单屏逻辑尺寸 1728×1117。
- 工具链：CommandLineTools，Apple Swift 6.1.2，AppleClang 17；SDK 15.5。Swift 和 CMake 目标的最低部署版本均为 26.0，使用的是现有 SDK 已提供的公开 API。
- Swift 使用语言模式 6 和严格并发检查，构建参数 `-warnings-as-errors`；Objective-C++ 为 C++20、ARC、`-Wall -Wextra -Werror`。
- 本机没有 XCTest；自检采用可执行目标，实际调用 Metal。XPC/GPU 集成需在可访问图形会话的环境执行，受限沙箱内 Metal 设备不可用。
- 命令与目录见 [`macos/README.md`](../macos/README.md)。所有构建和图片产物位于已忽略的 `macos/.build/`。

## 2. 已完成的验证

| 项目 | 方法与结果 | 结论边界 |
| --- | --- | --- |
| 原生编译 | Swift 6 宿主、核心自检和 Objective-C++ XPC 探针均可编译；严格告警检查通过 | 没有编译完整 scene、CEF 或生产 bundle |
| 固定版 DXC | `42da79c4...` 原源码成功构建 arm64 `dxc` 与 `libdxcompiler.dylib`；顶点、片元 HLSL 编译为 Vulkan 1.1 SPIR-V，版本报告含固定提交号 | 仅编译器 smoke test；上游存在重复静态库等链接警告，未改其源码；真实 WE shader 与 scene staging 尚待验证 |
| Metal 图像 | 由自检生成四象限 PNG，实际编码 GPU 绘制并读取结果；检查方向、sRGB 中间色、比例与黑边 | 图片仅用于诊断，不证明 scene 色彩转换 |
| 桌面首帧 | 5 秒限时运行通过；窗口层级 `-2147483604`，低于 Finder 图标层，不成为 key window、点击穿透 | 单屏自动检查；Finder 实际点击、Spaces、多屏热插拔尚未验收 |
| 静态源调度 | 5 秒内完成 1 帧，无周期渲染定时器，结束后退出并关闭窗口 | 动态 scene 的仿真时钟未接入 |
| 两进程帧共享 | bundle 内 XPC service 创建三槽 IOSurface；使用 XPC 对象跨进程传递，消费端导入 Metal 纹理并 GPU 拷贝；105 帧像素检查通过 | Metal 到 Metal；不证明 Vulkan/MoltenVK 到 IOSurface 可用 |
| 归还与背压 | 三槽持有时拒绝额外写入；延迟读取后像素不变；重复 release、旧 sequence、旧 generation 被拒绝 | 探针协议尚非生产协议；没有覆盖所有 GPU 故障注入 |
| 暂停与重建 | 槽位在用时拒绝重建；全部归还后从 64×32 重建为 97×53；暂停期间不产帧，恢复后继续读取 | 使用保守的先排空再重建，尚未实现生产双 generation 过渡 |
| 进程退出 | 强制 XPC service 退出，消费端收到中断，仍可读取已导入且完成的最后一帧 | supervisor 重启与多 session 隔离未实现 |

GPU 回读仅在测试目标用于断言；未来 presenter 的生产链路仍采用 GPU 拷贝。XPC 探针由临时签名的 bundle 启动，没有注册常驻 launchd agent 或全局服务。

DXC 的原生配置和 shader 样本见 [ShaderCompiler 探针](../macos/Probes/ShaderCompiler/README.md)。`.dylib` 使用 `@rpath` 标识，所检查的链接依赖为系统库；这仍不代表生产 app 的打包、公证已完成。

## 3. 算法与所有权

帧池在一个串行队列中拥有全部状态。三槽各自按 `Free -> Writing -> Ready -> Free` 迁移；身份为 connection 内的 `generation + sequence + slot`。`Writing -> Ready` 只在 GPU 写入完成后发生，`Ready -> Free` 只接受匹配 token 的归还。超时或 GPU 失败不回收在用槽位。

槽位搜索为 O(3)，状态内存 O(3)。尺寸重建使用新 generation，申请完整候选资源后再替换；旧 generation 尚有租约时返回 busy。消费端先把共享纹理 GPU 拷贝到私有纹理，GPU 完成后才发送 release。图像诊断采用一次加载、纹理采样和等比适配，不在绘制回调中读取磁盘。

Swift AppKit 状态属于 MainActor；Metal completion 明确使用 `@Sendable`，再切回 MainActor。首次桌面运行曾在完成回调触发 Swift actor 断言，堆栈确认是旧 SDK 回调缺少 Sendable 标注引起的隔离推断。修复发生在回调边界，同一真实桌面用例重跑通过，没有禁用并发检查或增加重试。

## 4. 未关闭的关卡

1. 固定版 scene 的 macOS 构建、DXC staging、Linux 视频依赖拆分。
2. Vulkan/MoltenVK 与 IOSurface 的图像、同步、格式和设备互操作。
3. 标准粒子与 rope/trail 的 geometry 等价实现；必须先获得实际公共 assets/shader 和壁纸样本。
4. CEF bundle、GPU 画面、输入与进程生命周期。
5. 桌面左键与 Finder 共存，Spaces/Mission Control/Stage Manager、多显示器及睡眠唤醒。

已向用户索取真实 scene 壁纸和公共 assets 的本机路径。未取得素材前，诊断图像或合成 shader 都不能作为 Wallpaper Engine 兼容性验收。P0 整体仍在进行中。
