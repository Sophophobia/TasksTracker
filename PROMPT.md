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
> - One file per project (I can load several). The widget shows the **project
>   name** = the file name without `.md`, unless the file's first heading is
>   `# Project: <name>` (then that wins).
>
> **Structure**
> 1. *(Optional)* First line: `# Project: <Project Name>`.
> 2. Group tasks under **status** sections (`##` headings), recognized by emoji
>    or word:
>    - `## 🔄 In progress`  (also: WIP / Doing / Ongoing)
>    - `## ⏳ Pending`       (also: Todo / Backlog / Planned / Later)
>    - `## ✅ Done`          (also: Completed / Finished / Shipped)
> 3. Each task is a `###` (or `####`) heading:
>    `### #<id> · <title>`
>    - `#<id>`: a number, **unique within the file**, kept stable (e.g. `#12`).
>      The number is required so the widget can tell tasks from ordinary headings.
>    - separator after the id: `·` (you may also use `-` or `:`, or just a space).
>    - `<title>`: one line. Long titles are fine — the widget wraps them when I
>      click the row.
>    - A status emoji at the **start of the title** overrides the section
>      (e.g. `### #5 · 🔄 ...`).
> 4. *(Optional)* Any other `#` heading (not `# Project:`) groups tasks into a
>    named **category** shown as the row's tag.
> 5. Everything else is ignored — legends, notes, `- **File:** ...`, etc. are safe.
>
> **Example**
> ```markdown
> # Project: Website Redesign
>
> ## 🔄 In progress
> ### #1 · Rework the homepage hero section
> ### #2 · Wire up the contact form
>
> ## ⏳ Pending
> ### #3 · Add a dark-mode toggle
>
> ## ✅ Done
> ### #4 · Set up the deploy pipeline
> ```
>
> When I ask you to update tasks: edit the file in place (move tasks between
> status sections, add new ones with the next id), keep it **UTF-8**, and don't
> reformat the parts above into anything else.

---

<a name="中文"></a>

## 中文 prompt

> 我在用一个 Windows 桌面小挂件 **Tasks Tracker**,它会从一个或多个 Markdown 文件里
> 读取并显示我的任务。请按下面的**确切格式**帮我创建和维护任务文件。
>
> **文件规则**
> - 纯 Markdown,**以 UTF-8 保存**。
> - 一个文件 = 一个项目(我可以同时加载多个)。挂件显示的**项目名 = 文件名(去掉
>   `.md`)**;若文件首个标题是 `# Project: <名字>`,则以它为准。
>
> **结构**
> 1. *(可选)* 首行:`# Project: <项目名>`。
> 2. 用 `##` 标题分**状态段**,靠 emoji 或英文词识别:
>    - `## 🔄 In progress`(也认 WIP / Doing / Ongoing)
>    - `## ⏳ Pending`(也认 Todo / Backlog / Planned / Later)
>    - `## ✅ Done`(也认 Completed / Finished / Shipped)
> 3. 每条任务是 `###`(或 `####`)标题:
>    `### #<编号> · <标题>`
>    - `#<编号>`:数字,**文件内唯一**且保持稳定(如 `#12`)。**编号必填** —— 挂件靠
>      它把任务和普通标题区分开。
>    - 编号后的分隔符:`·`(也可用 `-` 或 `:`,或只用一个空格)。
>    - `<标题>`:一行;标题很长也没关系,点击该行会展开换行显示。
>    - 标题**开头**的状态 emoji 会覆盖所在段的状态(如 `### #5 · 🔄 ...`)。
> 4. *(可选)* 其他 `#` 标题(非 `# Project:`)会作为任务的**分类标签**显示。
> 5. 其余内容一律忽略 —— 图例、笔记、`- **File:** ...` 等都安全。
>
> **示例**
> ```markdown
> # Project: 网站改版
>
> ## 🔄 In progress
> ### #1 · 重做首页 Hero 区
> ### #2 · 接好联系表单
>
> ## ⏳ Pending
> ### #3 · 加深色模式开关
>
> ## ✅ Done
> ### #4 · 搭好部署流水线
> ```
>
> 当我让你更新任务时:就地编辑该文件(在状态段之间移动任务、用下一个编号新增),保持
> **UTF-8**,不要把上面的结构改成别的形式。
