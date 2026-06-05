# Tasks Tracker — file-format prompt

Paste the prompt below to **your own AI assistant** (Claude, ChatGPT, etc.) so it
creates and maintains your task file(s) in the format the Tasks Tracker panel can
read. One file = one project; you can track several at once.

---

## English prompt

> I use a small Windows desktop widget called **Tasks Tracker** that displays my
> tasks from one or more Markdown files. Please create and maintain my task
> file(s) in the exact format below.
>
> **File rules**
> - Plain Markdown, saved as **UTF-8**.
> - One file per project (I can load several). The project name = the file name
>   without `.md`, unless the file starts with `# Project: <name>`.
>
> **Status legend (REQUIRED)**
> Declare the statuses in a `## Status legend` section, one per line, in the
> order I want them shown:
> ```
> ## Status legend
> - In progress
> - Pending
> - Done
> ```
> - One status per `- ` line. Name them anything (e.g. Backlog, Review, Blocked)
>   and use any number of them.
> - **The line order is the display order** of the groups in the panel.
> - Optional color per line: `- In progress | #3b82f6` or a color name
>   (blue, amber, green, red, purple, cyan, pink, gray).
>
> **Structure**
> 1. *(Optional)* First line: `# Project: <Project Name>`.
> 2. Group tasks under `##` **status sections** whose heading matches a status
>    name from the legend, e.g. `## In progress`, `## Done`.
> 3. Each task is a `###` (or `####`) heading: `### #<id> · <title>`
>    - `#<id>`: a number, unique within the file, kept stable (e.g. `#12`).
>      Required, so the widget can tell tasks from ordinary headings.
>    - separator after the id: `·`, `-`, `:`, or just a space.
>    - `<title>`: one line; long titles are fine (the widget wraps them on click).
> 4. *(Optional)* Any other `#` heading (not `# Project:`) groups tasks into a
>    named **category** shown as the row's tag.
> 5. Everything else is ignored — notes, `- **File:** ...`, etc. are safe.
>
> **What the panel does (so there are no surprises)**
> - Groups appear in the legend's line order.
> - A status with no `| color` is auto-colored by position: blue, amber, green,
>   purple, red, cyan, pink, gray (repeats after 8).
> - If no file has a `## Status legend`, the panel shows "No status legend found"
>   instead of guessing.
> - A task not under any recognized status section is shown under an **Other** group.
>
> **Example**
> ```markdown
> # Project: Website Redesign
>
> ## Status legend
> - In progress
> - Pending
> - Done
>
> ## In progress
> ### #1 · Rework the homepage hero section
> ### #2 · Wire up the contact form
>
> ## Pending
> ### #3 · Add a dark-mode toggle
>
> ## Done
> ### #4 · Set up the deploy pipeline
> ```
>
> When I ask you to update tasks: edit the file in place (move tasks between
> status sections, add new ones with the next id), **keep the `## Status legend`**,
> keep it **UTF-8**, and don't reformat the parts above into anything else.

---

<a name="中文"></a>

## 中文 prompt

> 我在用一个 Windows 桌面小挂件 **Tasks Tracker**,它会从一个或多个 Markdown 文件里
> 读取并显示我的任务。请按下面的**确切格式**帮我创建和维护任务文件。
>
> **文件规则**
> - 纯 Markdown,**以 UTF-8 保存**。
> - 一个文件 = 一个项目(我可以同时加载多个)。项目名 = 文件名(去掉 `.md`);若文件以
>   `# Project: <名字>` 开头,则以它为准。
>
> **状态图例(必填)**
> 在 `## Status legend` 段里逐行声明状态,**顺序就是面板里的显示顺序**:
> ```
> ## Status legend
> - In progress
> - Pending
> - Done
> ```
> - 每行一个状态(`- ` 开头)。名字随意(如 Backlog、Review、Blocked),数量任意。
> - **行的先后 = 面板分组从上到下的顺序。**
> - 每行可选颜色:`- In progress | #3b82f6` 或颜色名
>   (blue、amber、green、red、purple、cyan、pink、gray)。
>
> **结构**
> 1. *(可选)* 首行:`# Project: <项目名>`。
> 2. 用 `##` **状态段**分组,段标题需与图例里的某个状态名匹配,如 `## In progress`、`## Done`。
> 3. 每条任务是 `###`(或 `####`)标题:`### #<编号> · <标题>`
>    - `#<编号>`:数字,文件内唯一且稳定(如 `#12`)。**必填** —— 挂件靠它区分任务和普通标题。
>    - 编号后的分隔符:`·`、`-`、`:` 或一个空格。
>    - `<标题>`:一行;很长也没关系,点击该行会展开换行显示。
> 4. *(可选)* 其他 `#` 标题(非 `# Project:`)作为任务的**分类标签**显示。
> 5. 其余内容一律忽略 —— 笔记、`- **File:** ...` 等都安全。
>
> **挂件的既定行为(避免意外):**
> - 分组按图例行的顺序显示。
> - 没写 `| 颜色` 的状态按位置自动配色:blue、amber、green、purple、red、cyan、pink、gray(超过 8 个循环)。
> - 若没有任何文件含 `## Status legend`,面板显示「No status legend found」,不猜。
> - 不在任何已识别状态段下的任务,归到 **Other** 分组。
>
> **示例**
> ```markdown
> # Project: 网站改版
>
> ## Status legend
> - In progress
> - Pending
> - Done
>
> ## In progress
> ### #1 · 重做首页 Hero 区
> ### #2 · 接好联系表单
>
> ## Pending
> ### #3 · 加深色模式开关
>
> ## Done
> ### #4 · 搭好部署流水线
> ```
>
> 当我让你更新任务时:就地编辑该文件(在状态段之间移动任务、用下一个编号新增),
> **保留 `## Status legend`**,保持 **UTF-8**,不要把上面的结构改成别的形式。
