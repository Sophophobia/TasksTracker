# Tasks Tracker

> A tiny, always-on-top, **read-only** floating panel for Windows that shows your
> task list parsed live from one or more Markdown files. Edit the file(s) in your
> editor or have an AI update them — the panel refreshes within ~2 seconds. It
> never writes to your files.

It pairs well with an AI workflow: keep a `TASKS.md` per project, tell your AI to
maintain it (see [`PROMPT.md`](PROMPT.md)), and glance at this panel in a screen
corner to see what's in progress / pending / done across all your projects.

![screenshot](docs/screenshot.png)

## What it shows

- A dark, compact list grouped into collapsible sections, ordered **🔄 In progress**
  → **⏳ Pending** → **✅ Done**. Each header shows its count, e.g. `▾ In progress (7)`.
- Each row: `#id` · colored **status dot** (blue / amber / green) · a **tag**
  (the in-file category, or the project name) · the task **title**.
- **Multiple files / projects** are merged into the same status groups; each row's
  tag tells you which project (or category) it belongs to.
- **Done** is collapsed by default. **Click a section header** to collapse/expand it.
- Long titles are ellipsized; **click a row** to expand the full title (click again
  to collapse). Hovering also shows the full title as a tooltip.
- The top bar shows the last refresh time. Chinese renders in Microsoft YaHei UI,
  English in Segoe UI.

## Requirements

- Windows with **Windows PowerShell 5.1** (built in) — uses WinForms.
- No installation, no dependencies, single script.

## Install

Download / clone the folder anywhere, then double-click:

- **`Start Tasks Tracker.bat`** — opens the panel (no lingering console), **or**
- **`start.vbs`** — same thing with no console window at all.

Or run it directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "tasks-panel.ps1"
```

> Start at login: press `Win+R`, type `shell:startup`, and drop a shortcut to
> `start.vbs` into that folder.

## Point it at your tasks

On first run the panel opens a **file picker** — choose one or more task files.
You can change them anytime from the **☰ menu**:

- *Add task file(s)…* — pick one or more Markdown files (multi-select).
- *Remove file ▸* — drop a file from the panel.
- *Open file location ▸* — reveal a file in Explorer.

Your chosen files, window position/size and collapse state are saved in
`config.json` next to the script (per-machine; not shared).

## Task file format

A task file is plain **UTF-8 Markdown**. The full spec + a ready-to-paste prompt
for your AI is in [`PROMPT.md`](PROMPT.md); see [`TASKS.example.md`](TASKS.example.md)
for a working sample. In short:

- **Project name** = file name (without `.md`), unless the file starts with
  `# Project: <name>`.
- `##` headings = **status** sections, recognized by emoji or word
  (`🔄`/In progress · `⏳`/Pending · `✅`/Done, plus WIP/Todo/Backlog/Done synonyms).
- A **task** is `### #<id> · <title>` (id required; separator `·`, `-`, `:` or a
  space). A status emoji at the start of the title overrides the section.
- Any other `#` heading = an optional **category** shown as the row's tag.
- Everything else (legends, notes, `- **File:** …`) is ignored.

## Usage

- **Drag** the top bar to move; **drag the bottom-right grip** to resize.
- **↻** refresh now · **☰** menu · **✕** close.
- **Click a section header** to collapse/expand it.
- **Click a row** to expand a long title; click again to collapse.

The window is a tool-window: always on top, hidden from the taskbar / Alt-Tab,
and set to **not steal focus** — clicking it won't pull keyboard focus out of
whatever you're typing in.

## How it works

```
  one or more TASKS .md files  (you / your AI edit these)
            |  poll mtime every ~2s; re-parse only on change
            v
   tasks-panel.ps1  (PowerShell + WinForms, read-only)
            |  group by status, tag by project/category
            v
   always-on-top dark panel in a screen corner
```

Reads open with `FileShare.ReadWrite` and tolerate a file being rewritten
(e.g. by an auto-sync task): a locked/partial read just skips that round.

## Files

| File | Purpose |
|---|---|
| `tasks-panel.ps1` | The panel (PowerShell + WinForms, single file). |
| `start.vbs` | No-console launcher. |
| `Start Tasks Tracker.bat` | Double-click launcher. |
| `PROMPT.md` | Format spec + copy-paste prompt for your AI (EN / 中文). |
| `TASKS.example.md` | A working sample task file. |
| `config.json` | Per-machine state (files, window pos/size, collapse) — auto-created, git-ignored. |

## Notes & limitations

- Windows-only (WinForms). The dark scrollbar uses Windows dark-mode theming;
  on very old builds it falls back to the default scrollbar.
- Read-only by design — it never edits your task files.
- One status set (In progress / Pending / Done). Per-project **filtering** is on
  the roadmap.

## License

MIT — see [`LICENSE`](LICENSE).

---

<a name="中文"></a>

# 中文

> 一个极简、**只读**、常驻置顶的 Windows 悬浮小窗,实时显示从一个或多个 Markdown
> 文件解析出的任务清单。你在编辑器里改、或让 AI 改文件,面板都会在 ~2 秒内刷新。
> 它**绝不写入**你的文件。

适合配合 AI 工作流:每个项目放一个 `TASKS.md`,让 AI 按 [`PROMPT.md`](PROMPT.md)
维护它,然后把这个面板挂在屏幕角落,一眼看到所有项目里进行中 / 待办 / 完成的任务。

![截图](docs/screenshot.png)

## 显示什么

- 深色紧凑列表,按状态分**可折叠**段:**🔄 进行中** → **⏳ 待办** → **✅ 完成**,
  每段标题带计数,如 `▾ In progress (7)`。
- 每行:`#编号` · 彩色**状态点**(蓝 / 琥珀 / 绿) · 一个**标签**(文件内分类,或项目名)
  · 任务**标题**。
- **多文件 / 多项目**会合并进同一组状态里;每行的标签告诉你它属于哪个项目(或分类)。
- **完成**默认折叠。**点击段标题**即可折叠/展开。
- 标题过长会省略;**点击该行**展开完整标题(再点收起),悬停也有完整提示。
- 顶栏显示最后刷新时间。中文用微软雅黑、英文用 Segoe UI 渲染。

## 环境要求

- Windows,自带 **Windows PowerShell 5.1**(基于 WinForms)。
- 免安装、零依赖、单脚本。

## 安装

把文件夹放到任意位置,双击:

- **`Start Tasks Tracker.bat`** —— 打开面板(不留控制台窗口),或
- **`start.vbs`** —— 同上,完全无控制台闪现。

或直接运行:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "tasks-panel.ps1"
```

> 开机自启:`Win+R` 输入 `shell:startup`,把 `start.vbs` 的快捷方式拖进去。

## 指定你的任务文件

首次运行会弹出**文件选择器**,选一个或多个任务文件。之后随时可在 **☰ 菜单**里改:

- *Add task file(s)…* —— 选择一个或多个 Markdown 文件(可多选)。
- *Remove file ▸* —— 从面板移除某个文件。
- *Open file location ▸* —— 在资源管理器中定位文件。

你选的文件、窗口位置/大小、折叠状态都存在脚本旁的 `config.json`(本机私有,不共享)。

## 任务文件格式

任务文件是纯 **UTF-8 Markdown**。完整规范 + 一段可直接贴给 AI 的 prompt 见
[`PROMPT.md`](PROMPT.md);可运行的样例见 [`TASKS.example.md`](TASKS.example.md)。简述:

- **项目名** = 文件名(去掉 `.md`);若文件以 `# Project: <名字>` 开头,则以它为准。
- `##` 标题 = **状态段**,靠 emoji 或英文词识别(`🔄`/In progress · `⏳`/Pending ·
  `✅`/Done,另支持 WIP/Todo/Backlog/Done 等同义词)。
- **任务** 是 `### #<编号> · <标题>`(编号必填;分隔符 `·`、`-`、`:` 或空格)。标题
  开头的状态 emoji 会覆盖所在段。
- 其他 `#` 标题 = 可选的**分类**,作为该行标签显示。
- 其余内容(图例、笔记、`- **File:** …`)一律忽略。

## 用法

- **拖**顶栏移动;**拖**右下角小三角缩放。
- **↻** 立即刷新 · **☰** 菜单 · **✕** 关闭。
- **点击段标题**折叠/展开该段。
- **点击某行**展开长标题,再点收起。

这是个工具窗口:始终置顶、不出现在任务栏/Alt-Tab、且**不抢焦点** —— 点它不会把你
正在打字的输入焦点抢走。

## 工作原理

```
  一个或多个 TASKS .md 文件 (你 / 你的 AI 编辑)
            |  每 ~2 秒查一次 mtime;有变化才重新解析
            v
   tasks-panel.ps1  (PowerShell + WinForms, 只读)
            |  按状态分组,按项目/分类打标签
            v
   屏幕角落的常驻置顶深色面板
```

读取用 `FileShare.ReadWrite`,容忍文件被改写(比如 auto-sync):读到锁定/半截就
跳过这一轮、下一轮再读。

## 文件

| 文件 | 作用 |
|---|---|
| `tasks-panel.ps1` | 面板本体(PowerShell + WinForms,单文件)。 |
| `start.vbs` | 无控制台启动器。 |
| `Start Tasks Tracker.bat` | 双击启动器。 |
| `PROMPT.md` | 格式规范 + 给 AI 的现成 prompt(英文 / 中文)。 |
| `TASKS.example.md` | 可运行的样例任务文件。 |
| `config.json` | 本机状态(文件列表、窗口位置/大小、折叠)—— 自动生成,已 git 忽略。 |

## 说明 / 局限

- 仅 Windows(WinForms)。深色滚动条依赖 Windows 暗色主题,在很老的系统上会回退为
  默认滚动条。
- 设计上**只读**,绝不修改你的任务文件。
- 目前只有一套状态(进行中 / 待办 / 完成)。按项目**筛选**已在路线图上。

## 许可证

MIT —— 见 [`LICENSE`](LICENSE)。
