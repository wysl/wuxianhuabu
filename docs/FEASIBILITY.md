# 可行性调研报告

> 结论先行：**可行**，且比参考项目1 的路线更干净。但有三条必须承认的事实。
> 本文所有「已验证」条目都在一台真实 ComfyUI **0.42.1** 实例（4073 个节点类型）上跑过，附方法。

## 1. 三条硬约束（不是风险，是事实）

### 1.1 macOS arm64 无法在 Windows 上产出

Flutter 的 macOS 目标只能由 macOS 上的 Xcode 编译。Dart 代码 100% 共用，但产物必须换机器。

**做法**：`.github/workflows/build.yml` 用 `macos-14` runner 构建；本机只交付 Windows 产物。README 明确标注 macOS 未真机验证。

### 1.2 "x86" 实际只能是 x64

Flutter 官方 Windows 目标只有 `windows_x64` 与 `windows_arm64`（见 `flutter_tools/lib/src/build_info.dart` 的 `TargetPlatform` 枚举）。**没有 32 位**。

**做法**：按 x64 交付。已确认产物 PE 头为 `machine: 0x8664`。

### 1.3 不依赖浏览器，意味着展开器必须自研

这是本项目的核心技术风险。官方前端在浏览器里调 `app.graphToPrompt()` 把 UI 图展开成 API prompt；桌面端没有浏览器，所以要在 Dart 里重做这件事。

**为什么不能抄参考项目1**：`comfyui-gateway/src/ui-workflow.js` 的 `convertUiWorkflow()` 遇到 `definitions.subgraphs` 直接 `throw new Error("暂不支持包含 Subgraph 的工作流")`。而真实工作流大量使用子图。

**为什么不能只抄参考项目2**：它的 `mobile_graph.py` 依赖「电脑上开着 ComfyUI 网页」来生成模板，手机只覆盖值。这条路对桌面客户端不成立。

## 2. ComfyUI 侧能力核实

| 需要的能力 | 端点 | 核实结果 |
|---|---|---|
| 列已保存工作流 | `GET /v2/userdata?path=workflows` | ✅ 返回整棵树（`{name,path,type,size,modified}`） |
| 读工作流内容 | `GET /userdata/{file}` | ✅ **路径里的 `/` 必须 `%2F` 编码**，否则 404 |
| 节点定义/选项/范围 | `GET /object_info` | ✅ 6.7 MB，4073 个节点类 |
| 提交 | `POST /prompt` | ✅ 需 `client_id` 才能收进度 |
| 进度 | `WS /ws?clientId=` | ✅ 首帧须发 `{"type":"feature_flags"}` 才发预览帧 |
| 结果 | `GET /history/{id}` | ✅ 也保留**实际执行的 prompt**（见 §4） |
| 下载产物 | `GET /view` | ✅ 需带同样的认证头 |
| 上传素材 | `POST /upload/image` | ✅ 服务端可能改名，必须用返回值 |
| 取消 | `POST /interrupt` / `POST /queue` | ✅ 运行中中断、排队中删除 |

### 2.1 认证

ComfyUI **本体没有认证**（`server.py` 无 auth 中间件）。认证总在它前面：

- 反代 Basic（nginx `auth_basic`）
- `ComfyUI-Login` 的 session cookie + `Authorization: Bearer <token>` + `?token=` 兜底（见其 `password.py`）
- 网关自定义头（本项目实测实例用 `X-Api-Key`，无 key 返回 **401**）
- Cloudflare Access 的 `CF-Access-Client-Id/Secret`

客户端因此实现了 7 种策略，且**同一套头必须作用于 WebSocket 握手**——只给 HTTP 加认证的客户端会「出图正常但永远没有进度」，很难排查。

## 3. UI → API 展开：真实世界的坑

用 13 条真实工作流做了统计，结果直接决定了实现范围：

| 虚拟/特殊节点 | 出现次数 | `/object_info` 中有？ | 处理方式 |
|---|---|---|---|
| `GetNode` | 39 | ❌ 不存在 | 按 `Constant` 名沿作用域栈找 `SetNode`，取其生产者 |
| `SetNode` | 20 | ❌ 不存在 | 作为命名发布点，不进 prompt |
| `Reroute` | 9 | ❌ 不存在 | 穿透到真实生产者 |
| `PrimitiveFloat` 等 | 9 | ❌ 不存在 | 内联字面量 |
| `QQ-多值输入` | 有 | 存在但是空壳 | 内联字面量（**实测反推**） |

**关键实测**：向服务器提交一个含 `GetNode` 的 prompt，返回

```json
{"error":{"type":"missing_node_type","message":"Node 'GetNode' not found..."}}
```

即服务器**明确拒绝**未知 `class_type`。所以虚拟节点必须在客户端彻底解析掉，不能「透传让服务器处理」。

### 3.1 两个只有跑真实数据才会发现的 bug

**旁路节点不能简单丢弃。** `mode=4` 的节点不执行，但它的下游需要拿到值——正确行为是从它的**同类型输入**拼接。最初直接跳过，导致下游指向不存在的节点。

**`QQ-多值输入` 是值广播节点。** 它的输出链接在下游要内联成**字面量**，而不是 `[node, slot]`。证据来自实例 `/history`：实际执行的 prompt 里，下游拿到的是字符串本身：

```json
"986": {"class_type":"Text Multiline","inputs":{"text":"A continuous ultra-close ..."}}
```

这类节点在 `/object_info` 里是 `outputs:["*"]` 的空壳，靠读定义根本推不出来，只能看真实执行结果。

## 4. 判定「展开是否正确」的方法

这是本调研最有价值的部分：**不要靠人眼判断展开对不对**。

`GET /history/{prompt_id}` 对每个完成的任务同时保存：

- `prompt[2]` —— 服务器**实际执行的** API prompt
- `prompt[3].extra_pnginfo.workflow` —— 产生它的 UI 工作流

两者配对就是**ground truth**。`tools/export_history_pairs.py` 导出了 20 组去重后的配对，`test/history_oracle_test.dart` 用它逐字段比对。

这个方法立刻击穿了两个错误假设：

1. 曾以为 3 个 `GetNode`(CLIP/模型/VAE) 解析失败是展开器 bug。实际查 `prompt[3]` 发现，那次执行用的是**另一份** 7 节点工作流——保存的 JSON 与实例实际执行的内容不同步。展开器没问题。
2. 曾以为「节点集合相等」是充分条件。实际需要额外检查每个 `[execId, slot]` 链接的目标是否存在。

## 5. 参数表单的可行性

**问题**：只靠子图提升输入不够。13 条真实工作流里 **12 条完全没用子图**，参数表会是空的。

**做法**：三层来源，优先级从高到低——

1. 子图提升输入（作者显式公开的接口，带 label）
2. widget 直读（按 `widgets_values_named` → `inputs[].widget.name` → 位置兜底）
3. 技术字段默认折叠（模型名、采样器、文件名），避免首屏被下拉框淹没

实测：MOSS 工作流生成 **62 个可调参数**，含多行文本、滑块、下拉。

## 6. 提交前校验的价值

拿 `/object_info` 在**提交前**校验 combo 值与节点类型，能提前发现问题。对 26 个真实工作流跑出来的结果：

- **18 个干净**
- **8 个有问题**，全部是服务器端状态：
  - 3 个引用未安装的自定义节点（`WyslMediaIndexOutput` 等）
  - 4 个引用不存在的模型文件
  - 1 个 `QQRouteDispatch.select` 的值与服务器选项不符

这些不是客户端缺陷——服务器自己也会拒绝。价值在于**把它们从「提交后的神秘 400」变成「提交前的可读提示」**。

## 7. 端到端证据

真实跑通了一次完整链路（`test/live_generation_test.dart`，`COMFYUI_GENERATE=1`）：

```
using video_minimax_h3_t2v: 28 nodes, 40 parameters
submitted fdcb1cd5-...
status=success
images Wsl_20261030-1205.mp4 video output
```

提交的 prompt 里能看到子图执行路径 `140:119`、`140:120` 这类冒号 ID，证明展开器产出的结构与服务器预期一致。

另一次尝试（`d87fdab4`）卡在排队——因为先前的校验循环**真的提交了 26 个任务**占满队列。这暴露了测试设计问题：**校验不应提交**。已改为纯本地预检（读同一份 `/object_info`），不再占用 GPU 队列。

## 8. 工具链需求的实测结论

| 项 | 结论 |
|---|---|
| Flutter | 3.47.9 / Dart 3.13.7 可用，Windows 桌面工具链全绿 |
| Visual Studio | 2022 BuildTools 17.14 即可，需 `VC.Tools.x86.x64` + `VC.CMake.Project` + Windows SDK |
| **ATL** | **必需**。`flutter_secure_storage_windows` 依赖 `atlstr.h`，缺它链接失败（`error C1083`） |
| 开发者模式 | **必需**。Flutter 构建插件需要 symlink 支持，否则 `Building with plugins requires symlink support` |

## 9. 遗留与判断

- **macOS 未真机验证**：只有 CI 编译证据。
- **未做多版本 ComfyUI 兼容矩阵**：只在 0.42.1 上验证；对无 `/v2/userdata` 的老版本，客户端会报「读取工作流列表失败」而不是静默空白，但未做自动降级。
- **自定义节点的动态控件**：若节点在 `/object_info` 里没有声明某个 widget，它不会出现在表单里，但值会随工作流原样提交。这是保守选择。
- **画布未接生成结果**：生成产物目前显示在运行面板，尚未自动落成画布卡片（接口已具备，属于下一步）。
