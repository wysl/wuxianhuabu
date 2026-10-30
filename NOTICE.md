# NOTICE · 第三方来源说明

本项目以 MIT 许可发布。以下项目/资源在**调研阶段**被阅读、并在设计上提供了参考。本仓库**不包含**它们的代码副本。

## 参考项目（仅参考思路，未复制代码）

| 项目 | 许可 | 参考了什么 |
|---|---|---|
| [1314521gjy/ComfyUI-Local-Infinite-Canvas](https://github.com/1314521gjy/ComfyUI-Local-Infinite-Canvas) | MIT | 整体工程组织方式、工作流库/网关的产品形态、画布卡片的交互范式 |
| [wysl/QQ_ComfyUI_Tools](https://github.com/wysl/QQ_ComfyUI_Tools) | MIT | `mobile_graph.py` 的「用 `inputs[].widget.name` 标记按名取值」思路，以及子图提升输入的解析方向 |

两个项目均为 MIT。本项目在 Dart 中**重新实现**了展开逻辑，并对其中不足做了补强（见下），没有逐行移植。

### 相对参考实现的补强

调研中发现参考实现覆盖不到真实工作流的部分，本项目自行实现并各自有测试：

- **`SetNode` / `GetNode`**：参考实现未处理。真实工作流中 71 次使用；`/object_info` 里并不存在这两个类，必须客户端解析，否则服务器直接 `missing_node_type`。
- **值广播节点**（如 `QQ-多值输入`）：链接要内联成**字面量**而不是节点引用。这一点是从实例 `/history` 里实际执行过的 prompt 反推出来的。
- **旁路节点**（`mode=4`）：输出需要从**同类型输入**拼接，而不是简单丢弃。
- **`widgets_values_named`**：新版前端同时序列化命名映射，比按位置读数组更可靠；旧工作流没有它时回退到 `widget.name` 标记。

## 官方规范来源

- ComfyUI 源码（`server.py`、`app/user_manager.py`、`comfy_api/feature_flags.py`、`protocol.py`），用于确认端点、`/ws` 二进制帧格式与 `feature_flags` 握手要求。
- ComfyUI_frontend（`LGraphNode.ts` 的 `serialiseWidgetValues`、`ExecutableNodeDTO.ts` 的虚拟节点解析），用于确认序列化格式与 Set/Get 语义。

## 测试语料

`tools/fixtures/` 下的工作流 JSON 与 `tools/fixtures/history/pairs.json` 由 `tools/` 下的脚本从一台真实 ComfyUI 实例（0.42.1）导出，仅用于测试。其中的模型文件名、提示词等属于该实例的用户内容，不含凭据。

**凭据不入库**：`.gitignore` 排除 `cert/`、`*.pem`、`*.key`、`.env`。任何测试都通过环境变量读取 `COMFYUI_AUTH_TOKEN`，仓库内不存令牌。
