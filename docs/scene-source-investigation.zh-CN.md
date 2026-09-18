# Scene 源码溯源与依赖恢复记录

核查与恢复日期：2026-09-18。本文保留首次恢复时的 gitlink 和子模块状态，范围为 GitHub 元数据、固定提交源码与本地文件比对，以及全部递归子模块恢复。后续已按用户决定将 scene 源码直接纳入主仓库，第三方库继续使用子模块；当前目录管理见 [来源记录](../producer/third_party/wallpaper-scene-renderer/PROVENANCE.md)。恢复阶段未编译或运行壁纸，后续真实播放结果见 [scene 验证记录](macos-scene-validation.zh-CN.md)。

## 1. 结论

已恢复 Vivid 使用的原始 scene 渲染器，固定到与本地快照对应的提交 `0986aa4e48540eb9ec75786bde88e458ff7dc422`，并检出全部递归子模块。用户已确认以 Vivid 和该核心作为唯一移植基线，保留现有兼容行为。其他兼容核心不进入项目范围。

同时发现原移植方案需要修订：scene 强制要求 geometry shader，而查阅的 MoltenVK 实现不支持该功能。粒子和绳状效果实际使用几何阶段，因此不能只删除能力检查；必须设计并验证等价的几何展开路径。

## 2. 精确版本与本地缺失原因

| 项目 | 固定版本 / 位置 |
| --- | --- |
| 本地 Vivid 快照 | `68f3b07` |
| 对应原仓库提交 | [`ayasa520/Vivid@e5532360ff0c78dfb7a9689a12c2f4a3f9501797`](https://github.com/ayasa520/Vivid/tree/e5532360ff0c78dfb7a9689a12c2f4a3f9501797) |
| 原仓库的子模块路径 | `producer/third_party/wallpaper-scene-renderer` |
| scene 仓库 | [`ayasa520/wallpaper-scene-renderer`](https://github.com/ayasa520/wallpaper-scene-renderer) |
| 对应 scene 提交 | [`0986aa4e48540eb9ec75786bde88e458ff7dc422`](https://github.com/ayasa520/wallpaper-scene-renderer/tree/0986aa4e48540eb9ec75786bde88e458ff7dc422) |

核对过程与证据：

1. 原仓库 Git tree 在上述路径记录 mode `160000` 的 gitlink，指向 `0986aa4e...`；[GitHub 子模块记录](https://api.github.com/repos/ayasa520/Vivid/contents/producer/third_party/wallpaper-scene-renderer?ref=e5532360ff0c78dfb7a9689a12c2f4a3f9501797)可直接核对。
2. 将原仓库 tree 中的普通文件与本地 `git ls-tree -r HEAD` 比较：226 个文件的路径和 blob SHA 全部一致，普通文件没有缺失或差异。这包括 scene 的全部 7 个接入文件。
3. 恢复前，本地 `68f3b07` 保留了 `.gitmodules`，但没有对应 gitlink。因此本地问题是子模块记录/内容缺失，不是原作者未公开 scene。本轮已补回 mode `160000` 的 Git 索引项，并完成递归检出。
4. 已下载并解包指定提交到临时研究目录，确认核心源码、公共接口和构建文件实际存在；它不是只有 README 的空仓库。
5. 查询时 scene 仓库的 `master` 指向 `4e9bc7c2f347bde63f7dcee725d9188cf0d89e86`，与 Vivid 固定的提交不同。恢复时必须用 `0986aa4e...`，不能直接把最新 master 当作匹配版本。

以上证明来源和接入基线匹配，不代表已验证完整构建或运行效果。临时下载的 GitHub 源码归档不包含递归子模块内容。

## 3. 递归依赖

scene 的 [`.gitmodules`](https://github.com/ayasa520/wallpaper-scene-renderer/blob/0986aa4e48540eb9ec75786bde88e458ff7dc422/.gitmodules) 和 [Git tree](https://api.github.com/repos/ayasa520/wallpaper-scene-renderer/git/trees/0986aa4e48540eb9ec75786bde88e458ff7dc422?recursive=1) 固定了以下依赖：

| 子模块 | 来源 | 固定提交 |
| --- | --- | --- |
| DirectXShaderCompiler | microsoft/DirectXShaderCompiler | `42da79c4df141de195b78e8a92c5d1e40f2346f5` |
| Eigen | gitlab.com/libeigen/eigen | `3147391d946bb4b6c68edd901f2add6ac1f31f8c` |
| SPIRV-Reflect | KhronosGroup/SPIRV-Reflect | `c6c0f5c9796bdef40c55065d82e0df67c38a29a4` |
| miniaudio | mackron/miniaudio | `4a5b74bef029b3592c54b6048650ee5f972c1a48` |
| nlohmann/json | nlohmann/json | `0457de21cffb298c22b629e538036bfeb96130b7` |
| QuickJS-NG | quickjs-ng/quickjs | `01bce21cb70c771b372ac17a8ef9920ee105e972` |

上述 6 个直接子模块均已检出。更深层的 5 个子模块也已按各自父仓库的 gitlink 恢复：

| 父模块 / 子模块路径 | 固定提交 |
| --- | --- |
| DirectXShaderCompiler / `external/DirectX-Headers` | `980971e835876dc0cde415e8f9bc646e64667bf7` |
| DirectXShaderCompiler / `external/SPIRV-Headers` | `ad9184e76a66b1001c29db9b0a3e87f646c64de0` |
| DirectXShaderCompiler / `external/SPIRV-Tools` | `0539c81f69a3daeb706fd3477dca61435b475156` |
| SPIRV-Reflect / `third_party/googletest` | `52204f78f94d7512df1f0f3bea1d47437a2c3a58` |
| QuickJS-NG / `test262` | `a6f387de323eb9ae56448bdb71c5d315df631ce4` |

下载通过用户指定的 `http://127.0.0.1:7897` 代理完成，代理配置仅随命令传入；未修改上游 URL、`.gitmodules` 或依赖源码。使用浅层、blob 过滤下载，已检出固定版本的完整工作树，不代表下载了全部历史。

QuickJS 的 `.gitmodules` 将可选测试集 `test262` 设置为 `update = none`，普通递归命令会跳过它。本轮显式使用 `--checkout` 补齐；后续恢复命令见 [第三方依赖说明](../producer/third_party/README.md)。

恢复核对已通过：

- 主仓库索引中的 gitlink 与 scene HEAD 均为 `0986aa4e...`。
- scene 加 11 个递归子模块，共 12 个仓库的 HEAD 均匹配各自父仓库的固定引用；`git submodule status --recursive` 无未初始化、版本偏离或冲突标记。
- 12 个工作树均干净，80,736 个被跟踪的普通文件均存在。

本轮验证源码恢复及版本一致性；系统库安装、编译和真实壁纸运行仍待后续验证。

此外，构建使用 LZ4、Pango/Cairo、PangoFT2、Fontconfig、FreeType、Vulkan、GStreamer，以及 Linux 视频路径的 VA/CUDA/DRM 库。它们需按模块边界分离。文字栅格化与字体选择影响现有画面，不宜同时替换成另一套排版引擎。

scene 自带 `.clang-format`；移植时应遵守该子树的既有格式，再为新增 macOS 代码确定格式配置。

## 4. 这份 scene 包含的兼容能力

[固定版本 README](https://github.com/ayasa520/wallpaper-scene-renderer/blob/0986aa4e48540eb9ec75786bde88e458ff7dc422/README.md) 明确将支持范围描述为兼容子集，而非完整的 Wallpaper Engine 编辑器/运行时复刻。

文档列出图像、合成、文字、声音、粒子、灯光、shape、视差、PBR 光照、bloom、puppet、3D 模型、属性/时间轴动画、用户属性以及部分 SceneScript。源码中也存在对应解析器、渲染 pass 和 QuickJS 宿主。

它提供 `SceneWallpaper::mouseInput`、`mouseLeftButton`、属性设置，以及帧 ready/release 回调；当前 Vivid adapter 所用接口均能在这份源码中找到。脚本侧包含 cursor enter/leave/move/down/up/click 等兼容事件，但这不等于 macOS 已能可靠获取桌面点击。

已公开的功能缺口包括 camera fade、部分粒子 emitter duration、完整的编辑器鼠标跟随能力、粒子 children 的 audio response、完整 SceneScript API。后续验收应承认原基线本身的边界，不把全部缺口都归因于移植。

## 5. 新确认的 macOS 障碍

### 5.1 Geometry shader 是实际阻断项

[Device.cpp](https://github.com/ayasa520/wallpaper-scene-renderer/blob/0986aa4e48540eb9ec75786bde88e458ff7dc422/src/Vulkan/Device.cpp#L64) 在设备筛选时拒绝没有 `geometryShader` 的 GPU，创建时再次检查并启用它。

查阅的 [MoltenVK `4aaf714...` 实现](https://github.com/KhronosGroup/MoltenVK/blob/4aaf714aa1b3e78e26ecfcefa9c75e9a576c500b/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm#L2790) 将 features 清零后逐项启用支持能力，没有启用 `geometryShader`；几何阶段的相关 limits 也为 0。因此当前 scene 设备初始化不能直接通过。

这不是过度严格的检查而已：[粒子解析](https://github.com/ayasa520/wallpaper-scene-renderer/blob/0986aa4e48540eb9ec75786bde88e458ff7dc422/src/SceneParser/WPSceneParserParticle.cpp) 对 rope 材质要求几何阶段；[粒子数据生成](https://github.com/ayasa520/wallpaper-scene-renderer/blob/0986aa4e48540eb9ec75786bde88e458ff7dc422/src/Particle/WPParticleRawGener.cpp) 也为该 shader 输入准备了对应拓扑。

核心已有 `ParticleRenderPlan` 区分 `GeometryPoint` 和 `IndexedQuad`。后者仅用于原材质没有 geometry stage 的情况，不是所有 geometry shader 的等价替代。不能简单强制选择 IndexedQuad。

建议在该渲染计划边界设计能力适配：

- 对已经理解的标准 sprite，评估实例化四边形：单粒子 4 个顶点、6 个索引，O(P) 展开工作；保持旋转、UV、帧混合、深度和颜色语义。
- 对 rope/trail，先读取对应公共 assets 的几何 shader，明确曲线、相邻控制点、细分、宽度、UV、连接与裁剪语义，再评估顶点/计算阶段生成 ribbon。工作量和容量为 O(S×K)，S 为段数、K 为细分数，必须有容量上限。
- 对任意作者自定义的 geometry shader，不承诺自动转换；枚举实际样本，无法转换时明确报告不支持。

在看见具体 shader 与回归结果前不冻结上述算法。P0 必须同时验证普通 scene、geometry 粒子、rope/trail，不能以无粒子的单张成功画面证明总体兼容。

### 5.2 外部交换链还不是平台无关接口

`RenderInitInfo::ex_swapchain_factory` 的接入点真实存在，但返回的 `VulkanExSwapchain` 使用固定三槽、RGBA 格式和 Linux 外部句柄结构。

[ExSwapchain.hpp](https://github.com/ayasa520/wallpaper-scene-renderer/blob/0986aa4e48540eb9ec75786bde88e458ff7dc422/src/Swapchain/ExSwapchain.hpp) 的导出模式只有 `OPAQUE_FD`、`DMA_BUF`；[VulkanRender.cpp](https://github.com/ayasa520/wallpaper-scene-renderer/blob/0986aa4e48540eb9ec75786bde88e458ff7dc422/src/VulkanRender/VulkanRender.cpp#L62) 还把 external memory/semaphore FD 扩展设为必需。

因此 IOSurface 接入需要重构设备能力配置、交换链资源表示和同步契约；不能只向工厂传一个 Mac 回调。保留场景图和绘制行为，在资源所属边界做完整替换，符合“不堆叠补丁”的要求。

### 5.3 视频纹理与 shader 构建

`src/Vulkan/CMakeLists.txt` 无条件要求 GStreamer VA/CUDA、DRM、libva。普通 scene 的构建也会碰到这些依赖，需要先拆出视频解码平台实现。

DXC stage 的构建路径硬编码 `libdxcompiler.so`，scene 工程仍需平台化 staging。P0 已独立验证固定 DXC 版本的 macOS/arm64 构建与基础 HLSL 到 SPIR-V 编译，详见 [验证记录](macos-p0-validation.zh-CN.md)。QuickJS-NG、miniaudio 源码已恢复，仍需与字体库一起验证完整 scene 构建和运行。

## 6. 已确认的技术路线

以 `ayasa520/Vivid` 和其固定的 `ayasa520/wallpaper-scene-renderer` 为唯一兼容实现来源。当前移植以已有 Linux 行为为参考，重点处理 macOS 的设备能力、粒子展开、帧共享、视频解码、窗口与输入差异。

设备能力不匹配时，在现有渲染计划、资源和平台适配边界修改对应实现，并用原 Vivid 的真实壁纸验证等价性。保持一套内容解析、脚本语义和用户属性模型，不并入第二套 scene 引擎。

## 7. 推荐下一步

依赖恢复已经完成，macOS 方案已获批准并进入 P0；当前实施证据见 [P0 验证记录](macos-p0-validation.zh-CN.md)。后续继续：

1. 留存原提交的 Linux 运行基线。需要修改核心时，在本仓库中按平台边界提交并保留来源记录；禁止在构建时动态修补上游文件。
2. 将 P0 拆为设备能力/geometry 替代、帧共享、CEF 宿主、桌面输入四项验证，并把粒子效果对照作为通过条件。
3. 遇到原核心所需的 Mac 能力差异时，先完善对应算法和边界设计，按同一组 Vivid 壁纸比较。无法达到目标时明确报告具体功能差距，不自动更换兼容核心。

此时已经消除了“找不到 scene 来源”的问题。剩余主要风险是 Mac 图形能力差异以及桌面交互，不能以替换一个 Git 地址解决。
