# Tern Agent-Navigations 插件

Tern 的 Agent 跨 Session 导航器插件（类似 Herdr），提供全局 Agent 状态雷达面板与秒级定位跳转。

## 功能特性

1. **按 Session 分组展示**：
   - 自动聚合全局跨 Session 的所有 Agent Blocks。
   - 每个 Session 独立分栏（标明当前 Session、Agent 数量）。
2. **完整字段透视**：
   - **Harness**：智能识别 Agent 类型（`omp`、`acp`、`carly`、`claude`、`codex` 等）并附带模型版本（如 `omp • sonnet-3.7`）。
   - **Title**：读取 Pane Title，未命名时回退至 CWD 目录名称。
   - **Session Status**：
     - 🟡 `Working`：正在运行生成/工具调用
     - ❓ `Waiting Input`：等待用户人工确认/输入（高亮提示）
     - 🟢 `Idle`：已完成当前轮次，空闲
     - ⚪ `Exited`：进程已退出
     - ⚠️ `Error`：投递异常提示
   - **Last Message**：实时预览最近一条助手输出摘要。
3. **精准跳转**：
   - 点击卡片上的「Focus Agent →」按钮，自动切换至目标 Session 并聚焦到该 Block。
4. **灵活布局配置**：
   - **固定方向**：支持固定在 `left`（左侧）或 `right`（右侧，默认）。
   - **默认宽度**：约 240px（~28 终端字符列宽），保持侧边栏紧凑不挤占主编辑区。
5. **开启策略配置**：
   - `on_agent`（默认）：当前 Session 存在 Agent Block 时自动弹出常驻。
   - `always`：所有 Session 始终常驻开启。
   - `manual`：仅在用户按快捷键或呼出命令时开启。
   - 面板底部提供 Dock 按钮即时切换位置与开启模式（自动保存至 `tern.kv`）。
6. **全局快捷键**：
   - `Cmd+Alt+N`：快速展开/折叠 Agent-Nav 面板。
   - `Cmd+Shift+A`：呼出原生 Quick Jump Picker，支持全局键盘过滤并秒级切 Agent。
