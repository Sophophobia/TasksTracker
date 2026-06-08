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
> **Structure — free nesting by heading depth**
> Headings classify themselves, so you can nest as deep as you like. For any
> heading (other than `# Project:` and `## Status legend`):
> - It's a **status** if its text matches a legend status (by name, or a leading
>   status emoji). Status headings group the panel and can sit at any depth.
> - It's a **task** if it's `#<id> · <title>` (the leaf). `#<id>` starts with a
>   digit and is required, so the widget can tell tasks from headings. Separator
>   after the id: `·`, `-`, `:`, or a space. Titles can be long (wrap on click).
> - Otherwise it's an **intermediate level** (a category). Each becomes a column
>   in the row, nested by markdown depth (`#` → `##` → `###` …).
>
> So the only fixed rules are: **a status somewhere above each task, and the task
> as the leaf.** Any number of intermediate levels in between is fine — each one
> adds a column (and a filter dropdown in the panel). A task with fewer levels
> just leaves the trailing columns blank. Everything else (notes, `- **File:**
> …`) is ignored.
>
> Ids only need to be unique **within their own branch** — the panel locates a
> task by its full path, so `#1` can appear under different branches. (Unique
> across the file is still the safest if you're unsure.)
>
> **What the panel does (so there are no surprises)**
> - Groups appear in the legend's line order; a status with no `| color` is
>   auto-colored by position: blue, amber, green, purple, red, cyan, pink, gray.
> - If no file has a `## Status legend`, it shows "No status legend found".
> - A task with no status above it is shown under an **Other** group.
>
> **Example — one level (status → task)**
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
>
> ## Done
> ### #2 · Set up the deploy pipeline
> ```
>
> **Example — extra levels (status → Area → Sub-area → task)**
> ```markdown
> ## In progress
> ### Career
> #### WRA
> ##### #1 · Fix the milestone stepper
> #### CPC
> ##### #3 · Trim the channel list
> ### Wellness
> #### #10 · Rework the welcome popup    (no sub-area → that column is blank)
> ```
> The panel shows two columns (`Career | WRA`, `Wellness |`) and two filter
> dropdowns, one per level.
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
> **结构 —— 按标题深度自由嵌套**
> 标题会自我归类,所以你想嵌多深都行。对任意标题(除 `# Project:` 和 `## Status legend`):
> - 文本与图例某状态匹配(名字,或开头的状态 emoji)→ 它是**状态**(分组),可在任意层。
> - 形如 `#<编号> · <标题>` → 它是**任务**(最后一层)。`#<编号>` 数字开头、**必填**
>   (挂件靠它区分任务和普通标题)。分隔符:`·`、`-`、`:` 或空格。标题可长(点击展开)。
> - 其余 → **中间层级**(分类)。每一层在行里显示成一个**列**,按 markdown 深度
>   (`#` → `##` → `###` …)决定父子。
>
> 所以唯一的硬规则是:**每条任务上面要有一个状态,任务本身是叶子。** 中间想加几层都行 ——
> 每一层多一个列(面板里也多一个筛选下拉框)。某条任务层级少,后面的列就留空。其余内容
> (笔记、`- **File:** …`)一律忽略。
>
> 编号只需在**自己这一支(branch)里唯一** —— 面板按完整路径定位任务,所以不同分支下可以都有
> `#1`。(拿不准就全文件唯一,最稳妥。)
>
> **挂件的既定行为(避免意外):**
> - 分组按图例行顺序显示;没写 `| 颜色` 的状态按位置自动配色(blue、amber、green、purple、
>   red、cyan、pink、gray)。
> - 若没有任何文件含 `## Status legend`,显示「No status legend found」。
> - 上面没有任何状态的任务,归到 **Other** 分组。
>
> **示例 —— 一层(状态 → 任务)**
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
>
> ## Done
> ### #2 · 搭好部署流水线
> ```
>
> **示例 —— 多层(状态 → 区域 → 子区域 → 任务)**
> ```markdown
> ## In progress
> ### Career
> #### WRA
> ##### #1 · 修 milestone stepper
> #### CPC
> ##### #3 · 精简渠道列表
> ### Wellness
> #### #10 · 重做 welcome popup     (无子区域 → 该列留空)
> ```
> 面板会显示两列(`Career | WRA`、`Wellness |`)和两个筛选下拉框,每层一个。
>
> 当我让你更新任务时:就地编辑该文件(在状态段之间移动任务、用下一个编号新增),
> **保留 `## Status legend`**,保持 **UTF-8**,不要把上面的结构改成别的形式。
