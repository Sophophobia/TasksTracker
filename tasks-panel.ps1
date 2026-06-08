<#
  tasks-panel.ps1  --  Tasks Tracker floating panel

  A small, always-on-top, draggable + resizable panel that shows a live task
  list parsed from one or more Markdown files. It polls their mtime (~2s) and
  re-parses when any changes. It only writes on an explicit user action --
  right-click a task to edit its title or change its status; the change is
  applied to that task in place and written back (temp file + copy-overwrite).

  Tolerant of a file being rewritten underneath it (e.g. an auto-sync task):
  reads open with FileShare.ReadWrite and a failed/locked read just skips that
  round and retries next tick.

  Format (see PROMPT.md / TASKS.example.md):
    - One Markdown file per project (you can load several). UTF-8.
    - Project name = file name (without .md), unless the file has `# Project: X`.
    - `##` headings = status sections (emoji or words: In progress / Pending / Done).
    - Tasks: `### #<id> [sep] <title>`  (sep = . - : or space; id required).
    - Other `#` headings = optional in-file category (shown as the row tag).
    - Everything else is ignored.

  Display: dark, compact, grouped by status (In progress -> Pending -> Done).
  Each row: # | colored status dot | tag (category or project) | title. Click a
  row to expand a long title; click a section header to collapse it.

  Config (window pos/size, loaded files, per-section collapse) is saved to
  config.json next to this script, so the folder is portable. config.json is
  per-machine and is NOT committed.

  NOTE ON ENCODING: Windows PowerShell 5.1 reads .ps1 as ANSI unless the file
  has a UTF-8 BOM, which would corrupt non-ASCII literals. To stay robust this
  script is pure ASCII and builds non-ASCII glyphs from code points at runtime.

  Launch hidden via start.vbs, or directly:
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tasks-panel.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Borderless HUD form: shows without stealing focus, never activates on click
# (so clicking it won't yank keyboard focus from what you're typing in), and
# stays out of the taskbar + alt-tab.
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
public class HudForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            return cp;
        }
    }
}
"@

# Dark Explorer scrollbar (needs the process to opt into dark mode first via the
# undocumented uxtheme ordinals). All guarded so older builds just no-op.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Dark {
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi)] static extern IntPtr LoadLibrary(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GetProcAddress(IntPtr h, IntPtr ordinal);
    [DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hWnd, string sub, string id);
    delegate int  SetPreferredAppModeDel(int mode);
    delegate bool AllowDarkModeForWindowDel(IntPtr hWnd, bool allow);
    static IntPtr ux = IntPtr.Zero;
    static IntPtr Ux() { if (ux == IntPtr.Zero) ux = LoadLibrary("uxtheme.dll"); return ux; }
    public static void SetAppDark() {
        try { IntPtr p = GetProcAddress(Ux(), (IntPtr)135);
            if (p != IntPtr.Zero) { var d = (SetPreferredAppModeDel)Marshal.GetDelegateForFunctionPointer(p, typeof(SetPreferredAppModeDel)); d(2); } } catch { }
    }
    public static void DarkScroll(IntPtr hWnd) {
        try { IntPtr p = GetProcAddress(Ux(), (IntPtr)133);
            if (p != IntPtr.Zero) { var d = (AllowDarkModeForWindowDel)Marshal.GetDelegateForFunctionPointer(p, typeof(AllowDarkModeForWindowDel)); d(hWnd, true); } } catch { }
        try { SetWindowTheme(hWnd, "DarkMode_Explorer", null); } catch { }
    }
}
"@
[Dark]::SetAppDark()

# ----------------------------------------------------- non-ASCII glyphs -----
$G = @{
    inprog  = [char]::ConvertFromUtf32(0x1F504)   # cycle      (parse only)
    pending = [char]::ConvertFromUtf32(0x23F3)    # hourglass  (parse only)
    done    = [char]::ConvertFromUtf32(0x2705)    # check      (parse only)
    mid     = [char]0x00B7                          # middot separator
    emdash  = [char]0x2014                          # em dash separator
    ring    = [char]0x25C9                          # title ring
    dot     = [char]0x25CF                          # status dot
    refresh = [char]0x21BB                          # clockwise arrow
    menu    = [char]0x2261                          # triple bar
    close   = [char]0x2715                          # x
    triDown = [char]0x25BE                          # expanded
    triRt   = [char]0x25B8                          # collapsed
    rollUp  = [char]0x25B4                          # roll up (collapse window to title)
}

# ------------------------------------------------------------- paths --------
$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$PidFile    = Join-Path $PSScriptRoot 'panel.pid'

# ------------------------------------------------------------- config -------
$script:Files     = @()      # list of absolute file paths to read
$script:PosX = $null; $script:PosY = $null
$script:PosW = 440; $script:PosH = 470
$script:Collapsed = @{}   # status key -> $true if that section is collapsed
$script:Rolled    = $false   # window collapsed to just the title bar
$script:WrapAll   = $false   # wrap (expand) every task title to full text
$script:lastUpdateCheck = 0  # epoch seconds of last update check

# ---- update check state ----
$RepoUrl    = 'https://github.com/Sophophobia/TasksTracker'
$VersionUrl = 'https://raw.githubusercontent.com/Sophophobia/TasksTracker/main/VERSION'
$ScriptUrl  = 'https://raw.githubusercontent.com/Sophophobia/TasksTracker/main/tasks-panel.ps1'
$script:LocalVersion    = try { ([string](Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw)).Trim() } catch { '0' }
$script:UpdateAvailable = $false
$script:RemoteVersion   = $null
$script:updPS = $null; $script:updHandle = $null; $script:updManual = $false

function Load-Config {
    try {
        if (Test-Path $ConfigPath) {
            $c = Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($c.files)        { $script:Files = @($c.files | Where-Object { $_ }) }
            elseif ($c.file)     { $script:Files = @([string]$c.file) }   # legacy single-file
            if ($null -ne $c.x)  { $script:PosX = [int]$c.x }
            if ($null -ne $c.y)  { $script:PosY = [int]$c.y }
            if ($null -ne $c.w)  { $script:PosW = [int]$c.w }
            if ($null -ne $c.h)  { $script:PosH = [int]$c.h }
            if ($null -ne $c.rolled) { $script:Rolled = [bool]$c.rolled }
            if ($null -ne $c.wrapAll) { $script:WrapAll = [bool]$c.wrapAll }
            if ($null -ne $c.lastUpdateCheck) { $script:lastUpdateCheck = [long]$c.lastUpdateCheck }
            if ($null -ne $c.collapsed) {
                $script:Collapsed = @{}
                foreach ($p in $c.collapsed.PSObject.Properties) { $script:Collapsed[$p.Name] = [bool]$p.Value }
            }
        }
    } catch { }
}

function Save-Config {
    try {
        $obj = [ordered]@{
            files     = @($script:Files)
            x = $script:PosX; y = $script:PosY; w = $script:PosW; h = $script:PosH
            rolled = $script:Rolled
            wrapAll = $script:WrapAll
            lastUpdateCheck = $script:lastUpdateCheck
            collapsed = $script:Collapsed
        }
        ($obj | ConvertTo-Json -Compress) | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { }
}

# ------------------------------------------------------------- parsing ------
function Read-TasksFile($path) {
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8); return $sr.ReadToEnd() }
        finally { $fs.Dispose() }
    } catch { return $null }
}

$script:sepClass = '[' + $G.mid + ':' + $G.emdash + '|' + '\-' + ']'
$script:rxTaskSep = '^#{3,4}\s+#(\d+)(\S*)\s*' + $script:sepClass + '\s*(.+?)\s*$'
$script:rxTaskTxt = '^#{3,4}\s+#(\d+)(\S*)\s+(.+?)\s*$'
$script:rxTaskId  = '^#{3,4}\s+#(\d+)(\S*)\s*$'
$script:rxFile    = '^\s*-\s+\*\*Files?:\*\*'   # ignored content marker (for clarity)
# Project-line regexes built at runtime (colon class = ASCII ':' or full-width
# colon U+FF1A) so no non-ASCII literal lives in the source.
$script:colonChar  = [char]0xFF1A
$script:rxProj     = '^#\s+(?i:project)\s*[:' + $script:colonChar + ']\s*(.+?)\s*$'
$script:rxProjSkip = '^#\s+(?i:project)\s*[:' + $script:colonChar + ']'

# Drop leading emoji / symbols / spaces up to the first real word char (ASCII
# alphanumeric or a CJK ideograph). Pure code-point logic -> no non-ASCII source.
function Strip-LeadEmoji($s) {
    $cs = $s.ToCharArray()
    $i = 0
    for (; $i -lt $cs.Length; $i++) {
        $c = [int][char]$cs[$i]
        $alnum = ($c -ge 48 -and $c -le 57) -or ($c -ge 65 -and $c -le 90) -or ($c -ge 97 -and $c -le 122)
        $cjk   = ($c -ge 0x3400 -and $c -le 0x9FFF) -or ($c -ge 0x3040 -and $c -le 0x30FF) -or ($c -ge 0xAC00 -and $c -le 0xD7AF)
        if ($alnum -or $cjk) { break }
    }
    if ($i -ge $cs.Length) { return $s.Trim() }
    return $s.Substring($i).Trim()
}

# Strip a leading status emoji from a title and return @(status, cleanedTitle).
function Strip-StatusEmoji($title, $fallback) {
    if     ($title -match ('^\s*' + [regex]::Escape($G.inprog)))  { return @('InProgress', ($title -replace ('^\s*' + [regex]::Escape($G.inprog)  + '\s*'), '')) }
    elseif ($title -match ('^\s*' + [regex]::Escape($G.pending))) { return @('Pending',    ($title -replace ('^\s*' + [regex]::Escape($G.pending) + '\s*'), '')) }
    elseif ($title -match ('^\s*' + [regex]::Escape($G.done)))    { return @('Done',       ($title -replace ('^\s*' + [regex]::Escape($G.done)    + '\s*'), '')) }
    return @($fallback, $title)
}

# Split a legend bullet "- [emoji] Name (desc) | color" -> @{ emoji; name; color }.
function Parse-LegendLine($text) {
    $t = $text.Trim()
    $color = $null
    $bar = $t.LastIndexOf('|')
    if ($bar -ge 0) { $color = $t.Substring($bar + 1).Trim(); $t = $t.Substring(0, $bar).Trim() }
    $cs = $t.ToCharArray(); $i = 0
    for (; $i -lt $cs.Length; $i++) {
        $c = [int][char]$cs[$i]
        $alnum = ($c -ge 48 -and $c -le 57) -or ($c -ge 65 -and $c -le 90) -or ($c -ge 97 -and $c -le 122)
        $cjk   = ($c -ge 0x3400 -and $c -le 0x9FFF) -or ($c -ge 0x3040 -and $c -le 0x30FF) -or ($c -ge 0xAC00 -and $c -le 0xD7AF)
        if ($alnum -or $cjk) { break }
    }
    $emoji = ($t.Substring(0, $i)).Trim()
    $rest  = $t.Substring($i)
    $p = $rest.IndexOf('(')
    $name = $(if ($p -ge 0) { $rest.Substring(0, $p) } else { $rest }).Trim()
    return @{ emoji = $emoji; name = $name; color = $color }
}

# Extract the status definitions from a file's "## Status legend" section.
function Parse-Legend($raw) {
    $out = @()
    if ([string]::IsNullOrEmpty($raw)) { return $out }
    $inLegend = $false
    foreach ($line in ($raw -split "`n")) {
        $line = $line.TrimEnd("`r")
        if ($line -match '^##\s') {
            if ($line -match '(?i)status\s+legend') { $inLegend = $true; continue }
            elseif ($inLegend) { break }
        }
        if ($inLegend) {
            if ($line -match '^\s*-\s+(.+?)\s*$') { $p = Parse-LegendLine $matches[1]; if ($p.name) { $out += $p } }
            elseif ($line -match '^#') { break }
        }
    }
    return $out
}

# Build $script:Statuses from the union of all files' legends (first-seen order).
function Build-Statuses($raws) {
    $ordered = @(); $seen = @{}
    foreach ($raw in $raws) {
        foreach ($st in (Parse-Legend $raw)) {
            $k = $st.name.ToLower()
            if (-not $seen.ContainsKey($k)) {
                $seen[$k] = $true
                $ordered += [pscustomobject]@{ key = $k; name = $st.name; emoji = $st.emoji; color = $st.color; colorObj = $null }
            }
        }
    }
    $i = 0
    foreach ($s in $ordered) {
        $c = $(if ($s.color) { Resolve-Color $s.color } else { $null })
        if (-not $c) { $c = $script:Palette[$i % $script:Palette.Count] }
        $s.colorObj = $c; $i++
    }
    $script:Statuses = $ordered
}

# Match a heading to a status key: emoji first, then the longest status name found.
function Match-StatusInText($text) {
    foreach ($s in $script:Statuses) { if ($s.emoji -and $text.Contains($s.emoji)) { return $s.key } }
    $lower = $text.ToLower(); $best = $null; $bestLen = -1
    foreach ($s in $script:Statuses) {
        if ($s.key.Length -gt 0 -and $lower.Contains($s.key) -and $s.key.Length -gt $bestLen) { $best = $s.key; $bestLen = $s.key.Length }
    }
    return $best
}

# If a title starts with a status's emoji, return @(key, strippedTitle); else @($null, title).
function Match-InlineStatus($title) {
    foreach ($s in $script:Statuses) {
        if ($s.emoji -and ($title -match ('^\s*' + [regex]::Escape($s.emoji)))) {
            return @($s.key, ($title -replace ('^\s*' + [regex]::Escape($s.emoji) + '\s*'), ''))
        }
    }
    return @($null, $title)
}

# Parse one file's text into task records. $defaultProject is the fallback
# project name (the file name); a `# Project: X` line overrides it. $path is the
# source file (carried on each record so edits can be written back to it).
function Parse-File($raw, $defaultProject, $path) {
    $recs = @()
    if ([string]::IsNullOrEmpty($raw)) { return $recs }

    $project = $defaultProject
    # Pre-scan for a project override so it applies to the whole file.
    foreach ($line in ($raw -split "`n")) {
        if ($line -match $script:rxProj) { $project = $matches[1].Trim(); break }
    }

    $area = ''
    $section = $null   # current status key (from the matched `## ` section)
    foreach ($line in ($raw -split "`n")) {
        $line = $line.TrimEnd("`r")

        $m = $null
        if     ($line -match $script:rxTaskSep) { $m = @($matches[1], $matches[2], $matches[3]) }
        elseif ($line -match $script:rxTaskTxt) { $m = @($matches[1], $matches[2], $matches[3]) }
        elseif ($line -match $script:rxTaskId)  { $m = @($matches[1], $matches[2], '') }
        if ($m) {
            $id = $m[0] + $m[1]
            $inl = Match-InlineStatus $m[2]
            $stKey = $(if ($inl[0]) { $inl[0] } elseif ($section) { $section } else { '__other__' })
            $recs += [pscustomobject]@{
                id = $id; status = $stKey; area = $area; project = $project; task = ([string]$inl[1]).Trim(); file = $path
            }
            continue
        }

        if ($line -match '^##\s') {
            $ms = Match-StatusInText $line
            $section = $(if ($ms) { $ms } else { '__other__' })   # unrecognized section -> Other
            continue
        }

        if ($line -match '^#\s') {
            if ($line -match $script:rxProjSkip) { continue }   # the project line is not an area
            $area = Strip-LeadEmoji (($line -replace '^#\s+', '').Trim())
            continue
        }
    }
    return $recs
}

# ------------------------------------------------- write-back transforms ----
# All operate on text -> text (pure), so they can be unit-tested and applied to
# a fresh read just before an atomic write. Newlines are preserved (CRLF/LF).

function Task-Id($line) {
    if (($line -match $script:rxTaskSep) -or ($line -match $script:rxTaskTxt) -or ($line -match $script:rxTaskId)) {
        return ($matches[1] + $matches[2])
    }
    return $null
}

# Find the line index of the task whose (area, id) match, tracking the current
# "# <area>" heading exactly as Parse-File does (the `# Project:` line is not an
# area). Returns -1 if not found. Matching on area+id rather than id alone lets
# different areas reuse the same #ids without an edit hitting the wrong task.
function Find-TaskLine($lines, $area, $id) {
    $curArea = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^#\s') {
            if ($line -notmatch $script:rxProjSkip) { $curArea = Strip-LeadEmoji (($line -replace '^#\s+', '').Trim()) }
            continue
        }
        $tid = Task-Id $line
        if ($tid -and $tid -eq $id -and $curArea -eq $area) { return $i }
    }
    return -1
}

# Replace a task's title text in place (keeps level, #id, separator, and any
# leading inline status emoji).
function Set-TaskTitleText($text, $area, $id, $newTitle) {
    $nl = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
    $lines = @($text -split "`r?`n")
    $i = Find-TaskLine $lines $area $id
    if ($i -lt 0) { return $text }
    $ln = $lines[$i]
    $m = [regex]::Match($ln, $script:rxTaskSep)
    if (-not $m.Success) { $m = [regex]::Match($ln, $script:rxTaskTxt) }
    if ($m.Success) {
        $g = $m.Groups[3]
        $prefix = $ln.Substring(0, $g.Index)
        $inl = Match-InlineStatus $g.Value
        $lead = ''
        if ($inl[0]) { $st = Get-Status $inl[0]; if ($st -and $st.emoji) { $lead = $st.emoji + ' ' } }
        $lines[$i] = $prefix + $lead + $newTitle
    } else {
        $lines[$i] = $ln.TrimEnd() + ' ' + $G.mid + ' ' + $newTitle
    }
    return ($lines -join $nl)
}

# Add a "- <name>" line to the file's "## Status legend" (no-op if absent or
# already present).
function Add-LegendStatusText($text, $name, $color = '') {
    $nl = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
    $lines = @($text -split "`r?`n")
    $inLegend = $false; $legendHead = -1; $lastBullet = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^##\s') {
            if ($ln -match '(?i)status\s+legend') { $inLegend = $true; $legendHead = $i; continue }
            elseif ($inLegend) { break }
        }
        if ($inLegend) {
            if ($ln -match '^\s*-\s+(.+?)\s*$') {
                $lastBullet = $i
                if ((Parse-LegendLine $matches[1]).name.ToLower() -eq $name.ToLower()) { return $text }
            } elseif ($ln -match '^#') { break }
        }
    }
    if ($legendHead -lt 0) { return $text }
    $at = $(if ($lastBullet -ge 0) { $lastBullet + 1 } else { $legendHead + 1 })
    $bullet = $(if ([string]::IsNullOrWhiteSpace($color)) { "- $name" } else { "- $name | $color" })
    $arr = [System.Collections.ArrayList]@($lines)
    [void]$arr.Insert($at, $bullet)
    return ($arr -join $nl)
}

# Case-insensitive replace of the FIRST occurrence of $find in $s.
function Replace-First($s, $find, $repl) {
    if ([string]::IsNullOrEmpty($find)) { return $s }
    $idx = $s.IndexOf($find, [System.StringComparison]::OrdinalIgnoreCase)
    if ($idx -lt 0) { return $s }
    return $s.Substring(0, $idx) + $repl + $s.Substring($idx + $find.Length)
}

# Locate the "## Status legend" body: returns @(headIdx, endExclusive); bullets
# live between headIdx+1 and endExclusive. @(-1,-1) when there's no legend.
function Find-LegendRegion($lines) {
    $head = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($head -lt 0) {
            if ($ln -match '^##\s' -and $ln -match '(?i)status\s+legend') { $head = $i }
        } elseif ($ln -match '^#{1,6}\s') {
            return @($head, $i)
        }
    }
    if ($head -lt 0) { return @(-1, -1) }
    return @($head, $lines.Count)
}

# Remove a status's bullet from the legend. Its "## <name>" task sections are
# left in place; with no legend entry they no longer match, so their tasks fall
# into the "Other" (no-status) group automatically.
function Remove-LegendStatusText($text, $name) {
    $nl = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
    $lines = [System.Collections.ArrayList]@($text -split "`r?`n")
    $reg = Find-LegendRegion $lines; if ($reg[0] -lt 0) { return $text }
    for ($i = $reg[1] - 1; $i -ge $reg[0] + 1; $i--) {
        if ($lines[$i] -match '^\s*-\s+(.+?)\s*$' -and (Parse-LegendLine $matches[1]).name.ToLower() -eq $name.ToLower()) {
            $lines.RemoveAt($i)
        }
    }
    return ($lines -join $nl)
}

# Set (or clear, when $color is blank) the "| color" on a status's legend bullet.
function Set-LegendColorText($text, $name, $color) {
    $nl = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
    $lines = @($text -split "`r?`n")
    $reg = Find-LegendRegion $lines; if ($reg[0] -lt 0) { return $text }
    for ($i = $reg[0] + 1; $i -lt $reg[1]; $i++) {
        if ($lines[$i] -match '^(\s*-\s+)(.+?)\s*$') {
            $prefix = $matches[1]; $body = $matches[2]
            if ((Parse-LegendLine $body).name.ToLower() -eq $name.ToLower()) {
                $bar = $body.LastIndexOf('|'); if ($bar -ge 0) { $body = $body.Substring(0, $bar).TrimEnd() }
                if (-not [string]::IsNullOrWhiteSpace($color)) { $body = $body + ' | ' + $color }
                $lines[$i] = $prefix + $body
                break
            }
        }
    }
    return ($lines -join $nl)
}

# Rename a status: rewrite its legend bullet and any matching "## <oldName>"
# section headings (so the tasks under them stay grouped). Emoji / color / notes
# on those lines are preserved (only the name token is swapped).
function Rename-LegendStatusText($text, $oldName, $newName) {
    if ($oldName.ToLower() -eq $newName.ToLower()) { return $text }
    $nl = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
    $lines = @($text -split "`r?`n")
    $reg = Find-LegendRegion $lines
    if ($reg[0] -ge 0) {
        for ($i = $reg[0] + 1; $i -lt $reg[1]; $i++) {
            if ($lines[$i] -match '^\s*-\s+(.+?)\s*$' -and (Parse-LegendLine $matches[1]).name.ToLower() -eq $oldName.ToLower()) {
                $lines[$i] = Replace-First $lines[$i] $oldName $newName
                break
            }
        }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^##\s' -and $ln -notmatch '(?i)status\s+legend') {
            $h = Strip-LeadEmoji (($ln -replace '^##\s+', '').Trim())
            if ($h.ToLower() -eq $oldName.ToLower()) { $lines[$i] = Replace-First $ln $oldName $newName }
        }
    }
    return ($lines -join $nl)
}

# Reorder the legend bullets to match $orderedNames (statuses not listed keep
# their original relative order, after the listed ones). Non-bullet lines (blank
# lines, comments) stay put.
function Reorder-LegendText($text, $orderedNames) {
    $nl = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
    $lines = @($text -split "`r?`n")
    $reg = Find-LegendRegion $lines; if ($reg[0] -lt 0) { return $text }
    $idx = @()
    for ($i = $reg[0] + 1; $i -lt $reg[1]; $i++) { if ($lines[$i] -match '^\s*-\s+(.+?)\s*$') { $idx += $i } }
    if ($idx.Count -le 1) { return $text }
    $rank = @{}; $r = 0; foreach ($n in $orderedNames) { $rank[([string]$n).ToLower()] = $r; $r++ }
    $items = @()
    for ($k = 0; $k -lt $idx.Count; $k++) {
        $null = $lines[$idx[$k]] -match '^\s*-\s+(.+?)\s*$'
        $nm = (Parse-LegendLine $matches[1]).name.ToLower()
        $rk = $(if ($rank.ContainsKey($nm)) { $rank[$nm] } else { 1000000 })
        $items += [pscustomobject]@{ line = $lines[$idx[$k]]; rank = $rk; orig = $k }
    }
    $sorted = @($items | Sort-Object rank, orig)
    for ($k = 0; $k -lt $idx.Count; $k++) { $lines[$idx[$k]] = $sorted[$k].line }
    return ($lines -join $nl)
}

# Move a task's whole block (heading + following lines up to the next heading)
# to the "## <statusName>" section within the SAME area (`# ...` group). Creates
# the section at the end of the area if it doesn't exist there.
function Move-TaskStatusText($text, $area, $id, $statusName) {
    $nl = $(if ($text -match "`r`n") { "`r`n" } else { "`n" })
    $arr = [System.Collections.ArrayList]@($text -split "`r?`n")
    $s = Find-TaskLine $arr $area $id
    if ($s -lt 0) { return $text }
    $e = $arr.Count
    for ($i = $s + 1; $i -lt $arr.Count; $i++) { if ($arr[$i] -match '^#{1,6}\s') { $e = $i; break } }
    $block = @($arr.GetRange($s, $e - $s))

    $areaStart = -1
    for ($j = $s - 1; $j -ge 0; $j--) { if (($arr[$j] -match '^#\s') -and ($arr[$j] -notmatch '^##')) { $areaStart = $j; break } }
    $arr.RemoveRange($s, $e - $s)

    $areaEnd = $arr.Count
    for ($j = [Math]::Max($areaStart + 1, 0); $j -lt $arr.Count; $j++) { if (($arr[$j] -match '^#\s') -and ($arr[$j] -notmatch '^##')) { $areaEnd = $j; break } }
    $from = $(if ($areaStart -ge 0) { $areaStart + 1 } else { 0 })
    $key = $statusName.ToLower()

    $t = -1
    for ($j = $from; $j -lt $areaEnd; $j++) { if (($arr[$j] -match '^##\s') -and ((Match-StatusInText $arr[$j]) -eq $key)) { $t = $j; break } }
    if ($t -ge 0) {
        $tEnd = $areaEnd
        for ($j = $t + 1; $j -lt $areaEnd; $j++) { if ($arr[$j] -match '^#{1,2}\s') { $tEnd = $j; break } }
        $arr.InsertRange($tEnd, $block)
    } else {
        $ins = [System.Collections.ArrayList]@(); [void]$ins.Add(''); [void]$ins.Add("## $statusName"); $ins.AddRange($block)
        $arr.InsertRange($areaEnd, $ins)
    }
    return ($arr -join $nl)
}

# ----------------------------------------------------- theme (dark) ---------
$cBg     = [System.Drawing.Color]::FromArgb(17,17,19)
$cBar    = [System.Drawing.Color]::FromArgb(28,28,32)
$cBand   = [System.Drawing.Color]::FromArgb(34,34,40)
$cText   = [System.Drawing.Color]::FromArgb(228,230,235)
$cDim    = [System.Drawing.Color]::FromArgb(138,146,160)
$cHead   = [System.Drawing.Color]::FromArgb(158,168,184)
$cBarDim = [System.Drawing.Color]::FromArgb(140,146,158)
$cBorder = [System.Drawing.Color]::FromArgb(60,60,68)
$cInProg = [System.Drawing.Color]::FromArgb(59,130,246)
$cPending= [System.Drawing.Color]::FromArgb(245,158,11)
$cDone   = [System.Drawing.Color]::FromArgb(34,197,94)

# Color palette assigned to statuses by legend order when a status has no
# explicit "| color". (Documented in PROMPT.md.)
$script:Palette = @(
    [System.Drawing.Color]::FromArgb(59,130,246),   # blue
    [System.Drawing.Color]::FromArgb(245,158,11),   # amber
    [System.Drawing.Color]::FromArgb(34,197,94),    # green
    [System.Drawing.Color]::FromArgb(168,85,247),   # purple
    [System.Drawing.Color]::FromArgb(239,68,68),    # red
    [System.Drawing.Color]::FromArgb(34,211,238),   # cyan
    [System.Drawing.Color]::FromArgb(236,72,153),   # pink
    [System.Drawing.Color]::FromArgb(148,163,184)   # gray
)
$script:NamedColors = @{
    blue = $script:Palette[0]; amber = $script:Palette[1]; green = $script:Palette[2]
    purple = $script:Palette[3]; red = $script:Palette[4]; cyan = $script:Palette[5]
    pink = $script:Palette[6]; gray = $script:Palette[7]
}
$cOther = $script:Palette[7]

# Statuses come entirely from the files' "## Status legend" (built each refresh).
# Each: @{ key (lowercased name); name; emoji; color (raw); colorObj }
$script:Statuses = @()

function Resolve-Color($s) {
    $s = ([string]$s).Trim().ToLower()
    if ($s -match '^#([0-9a-f]{6})$') {
        return [System.Drawing.Color]::FromArgb(
            [Convert]::ToInt32($s.Substring(1,2),16),
            [Convert]::ToInt32($s.Substring(3,2),16),
            [Convert]::ToInt32($s.Substring(5,2),16))
    }
    if ($script:NamedColors.ContainsKey($s)) { return $script:NamedColors[$s] }
    return $null
}
function Get-Status($key) { foreach ($s in $script:Statuses) { if ($s.key -eq $key) { return $s } }; return $null }
function StatusColor($key) { $s = Get-Status $key; if ($s) { return $s.colorObj }; return $cOther }

# Fonts: Chinese text -> Microsoft YaHei UI, English -> Segoe UI (chosen per
# string, since a single WinForms label can't font-fallback mid-text).
$fBar   = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$fIcon  = New-Object System.Drawing.Font('Segoe UI', 11,  [System.Drawing.FontStyle]::Bold)
$fHead  = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$fIdEn  = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fDot   = New-Object System.Drawing.Font('Segoe UI', 9)
$fTime  = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fTaskEn = New-Object System.Drawing.Font('Segoe UI', 9)
$fTaskZh = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fTagEn  = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fTagZh  = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)

function Has-CJK($t) {
    foreach ($ch in $t.ToCharArray()) {
        $c = [int][char]$ch
        if (($c -ge 0x3400 -and $c -le 0x9FFF) -or ($c -ge 0x3040 -and $c -le 0x30FF) -or ($c -ge 0xAC00 -and $c -le 0xD7AF) -or ($c -ge 0xFF00 -and $c -le 0xFFEF)) { return $true }
    }
    return $false
}
function FTask($t) { if (Has-CJK $t) { return $fTaskZh } else { return $fTaskEn } }
function FTag($t)  { if (Has-CJK $t) { return $fTagZh }  else { return $fTagEn } }

$TitleH = 30
$RowH   = 23
$HeadH  = 22
$MinW   = 300
$MinH   = 160

$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 15000
$tip.InitialDelay = 350

# ------------------------------------------------------------- form ---------
Load-Config

$form = New-Object HudForm
$form.FormBorderStyle = 'None'
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.BackColor       = $cBg
# Expose a thin border band on all four sides that no docked child covers, so the
# form itself receives mouse events there and can be resized from any edge/corner.
$EdgeBand             = 5
$form.Padding         = New-Object System.Windows.Forms.Padding($EdgeBand)
$form.Width           = [Math]::Max($MinW, $script:PosW)
$form.Height          = [Math]::Max($MinH, $script:PosH)
$form.StartPosition   = 'Manual'

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($null -ne $script:PosX -and $null -ne $script:PosY) {
    $form.Location = New-Object System.Drawing.Point($script:PosX, $script:PosY)
    # Guard against an off-screen saved position (e.g. a monitor was unplugged):
    # if the window doesn't meaningfully overlap any screen, snap back on-screen.
    $rect = New-Object System.Drawing.Rectangle($script:PosX, $script:PosY, $form.Width, $form.Height)
    $onScreen = $false
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $i = [System.Drawing.Rectangle]::Intersect($scr.WorkingArea, $rect)
        if ($i.Width -ge 80 -and $i.Height -ge 40) { $onScreen = $true; break }
    }
    if (-not $onScreen) {
        $form.Location = New-Object System.Drawing.Point(($screen.Width - $form.Width - 14), 44)
        $script:PosX = $form.Location.X; $script:PosY = $form.Location.Y
    }
} else {
    $form.Location = New-Object System.Drawing.Point(($screen.Width - $form.Width - 14), 44)
}

$form.Add_Paint({
    param($s,$e)
    $pen = New-Object System.Drawing.Pen ($cBorder), 1
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
})

# ---- top bar ----
$bar = New-Object System.Windows.Forms.Panel
$bar.Height = $TitleH; $bar.Dock = 'Top'; $bar.BackColor = $cBar
$bar.Cursor = 'Default'   # don't inherit the form's transient resize cursor
$form.Controls.Add($bar)

$title = New-Object System.Windows.Forms.Label
$title.Text = $G.ring + '  Tasks Tracker'
$title.ForeColor = $cText; $title.Font = $fBar
$title.AutoSize = $false; $title.Dock = 'Fill'
$title.Padding = New-Object System.Windows.Forms.Padding(10,0,0,0)
$title.TextAlign = 'MiddleLeft'
$bar.Controls.Add($title)

function New-BarButton($glyph, $w) {
    $b = New-Object System.Windows.Forms.Label
    $b.Text = $glyph; $b.ForeColor = $cBarDim; $b.Font = $fIcon
    $b.Dock = 'Right'; $b.Width = $w; $b.TextAlign = 'MiddleCenter'; $b.Cursor = 'Hand'
    $b.Add_MouseEnter({ $this.ForeColor = $cText })
    $b.Add_MouseLeave({ $this.ForeColor = $cBarDim })
    return $b
}
# Update-available dot (hidden until an update is found). Leftmost of the right
# cluster so it reads as a small dot in the title bar.
$dotUpd = New-Object System.Windows.Forms.Label
$dotUpd.Text = $G.dot; $dotUpd.ForeColor = [System.Drawing.Color]::FromArgb(245,158,11)
$dotUpd.Font = $fDot; $dotUpd.AutoSize = $false; $dotUpd.Dock = 'Right'; $dotUpd.Width = 16
$dotUpd.TextAlign = 'MiddleCenter'; $dotUpd.Visible = $false; $dotUpd.Cursor = 'Hand'
$bar.Controls.Add($dotUpd)

$btnRoll    = New-BarButton $G.rollUp  26
$btnClose   = New-BarButton $G.close   30
$btnMenu    = New-BarButton $G.menu    28
$btnRefresh = New-BarButton $G.refresh 28
$bar.Controls.Add($btnRoll); $bar.Controls.Add($btnRefresh); $bar.Controls.Add($btnMenu); $bar.Controls.Add($btnClose)
$tip.SetToolTip($btnRoll, 'Collapse to title bar'); $tip.SetToolTip($btnRefresh, 'Refresh now'); $tip.SetToolTip($btnMenu, 'Menu'); $tip.SetToolTip($btnClose, 'Close panel')
$tip.SetToolTip($dotUpd, 'Update available')
$btnClose.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(248,113,113) })
$title.SendToBack()

# ---- scrollable content ----
$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'; $content.BackColor = $cBg; $content.AutoScroll = $true
$content.Cursor = 'Default'   # don't inherit the form's transient resize cursor
$form.Controls.Add($content)
$content.BringToFront()
try {
    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $dbProp.SetValue($content, $true, $null)
} catch { }

# ---- resize grip ----
$grip = New-Object System.Windows.Forms.Panel
$grip.Size = New-Object System.Drawing.Size(16,16); $grip.BackColor = [System.Drawing.Color]::Transparent
$grip.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$grip.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 16), ($form.ClientSize.Height - 16))
$grip.Cursor = 'SizeNWSE'
$grip.Add_Paint({
    param($s,$e)
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120,130,146))
    foreach ($d in @(@(11,11),@(7,11),@(11,7),@(3,11),@(11,3))) { $e.Graphics.FillRectangle($br, $d[0], $d[1], 2, 2) }
    $br.Dispose()
})
$form.Controls.Add($grip); $grip.BringToFront()

# ------------------------------------------------------------- rendering ----
$script:LastMtime = $null
$script:LastSig   = '__init__'
$script:LastRecs  = @()
$script:Expanded  = @{}     # row key -> $true (session-only)

function New-RowLabel($parent, $text, $x, $w, $color, $font, $align) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.ForeColor = $color; $l.Font = $font
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.AutoSize = $false; $l.AutoEllipsis = $true; $l.TextAlign = $align
    $l.Location = New-Object System.Drawing.Point($x, 0)
    $l.Size = New-Object System.Drawing.Size($w, $RowH)
    $l.Anchor = $script:aTL
    $parent.Controls.Add($l)
    return $l
}

function Id-Key($id) { if ($id -match '^(\d+)') { return [int]$matches[1] } return 0 }

function Row-Key($r) { return ('{0}|{1}|{2}' -f $r.project, $r.id, $r.task) }

function Toggle-Section($key) {
    $script:Collapsed[$key] = -not $script:Collapsed[$key]
    Save-Config
    Render-List $script:LastRecs
}

# Size the task label for its state and return the row height. Expanded uses an
# AutoSize label locked to the column width, so its Height is exactly the wrapped
# text height (no gap); a top inset keeps the first line at the same Y as the
# collapsed (centered) line, so expanding only adds lines below.
function Set-TaskLabelState($tl, $expand, $taskW) {
    $pad = [int][Math]::Max(2, ($RowH - 17) / 2)
    if ($expand) {
        $tl.AutoEllipsis = $false; $tl.TextAlign = 'TopLeft'
        $tl.MinimumSize = New-Object System.Drawing.Size($taskW, 0)
        $tl.MaximumSize = New-Object System.Drawing.Size($taskW, 0)
        $tl.AutoSize = $true
        $tl.Top = $pad
        return ([Math]::Max($RowH, $tl.Height + 2 * $pad))
    } else {
        $tl.AutoSize = $false
        $tl.MinimumSize = [System.Drawing.Size]::Empty
        $tl.MaximumSize = [System.Drawing.Size]::Empty
        $tl.AutoEllipsis = $true; $tl.TextAlign = 'MiddleLeft'
        $tl.Top = 0
        $tl.Size = New-Object System.Drawing.Size($taskW, $RowH)
        return $RowH
    }
}

function Toggle-Expand($key) {
    $expand = -not $script:Expanded.ContainsKey($key)
    if ($expand) { $script:Expanded[$key] = $true } else { $script:Expanded.Remove($key) }

    $row = $null
    foreach ($c in $content.Controls) { if (($c -is [System.Windows.Forms.Panel]) -and ([string]$c.Tag -eq [string]$key)) { $row = $c; break } }
    if (-not $row) { return }
    $tl = $null
    foreach ($k in $row.Controls) { if ($k.Name -eq 'ltask') { $tl = $k; break } }
    if (-not $tl) { return }

    # Wrap width = the row's real available width (not $tl.Width, which the L+R
    # anchor may have stretched past the visible area).
    $taskW = $row.ClientSize.Width - $tl.Left - 8
    if ($taskW -lt 60) { $taskW = 60 }
    $content.SuspendLayout()
    $row.Height = Set-TaskLabelState $tl $expand $taskW
    $content.ResumeLayout()
}

# Plain script-scope handlers (NOT closures) so $script:* + functions resolve;
# the per-row/section key rides on the control's .Tag.
$script:onSectionClick = { Toggle-Section $this.Tag }
$script:onRowClick     = { Toggle-Expand  $this.Tag }
$script:aTL  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$script:aTLR = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

function Render-List($recs) {
    if ($null -eq $recs) { return }
    $script:LastRecs = $recs

    $cw = $content.ClientSize.Width
    if ($cw -le 0) { $cw = $form.ClientSize.Width }

    $prevScroll = $content.AutoScrollPosition
    $content.SuspendLayout()
    $content.Controls.Clear()

    $order = @($script:Statuses | ForEach-Object { @{ key = $_.key; label = $_.name } })

    $taskX = 134
    $taskW = $cw - $taskX - 8
    if ($taskW -lt 60) { $taskW = 60 }

    $blocks = New-Object System.Collections.ArrayList
    foreach ($grp in $order) {
        $members = @($recs | Where-Object { $_.status -eq $grp.key })
        if ($members.Count -eq 0) { continue }
        $collapsed = [bool]$script:Collapsed[$grp.key]

        $hp = New-Object System.Windows.Forms.Panel
        $hp.Dock = 'Top'; $hp.Height = $HeadH; $hp.BackColor = $cBand; $hp.Cursor = 'Hand'
        $tri = if ($collapsed) { $G.triRt } else { $G.triDown }
        $hl = New-Object System.Windows.Forms.Label
        $hl.Text = ('{0}  {1}  ({2})' -f $tri, $grp.label, $members.Count)
        $hl.ForeColor = $cHead; $hl.Font = $fHead; $hl.BackColor = [System.Drawing.Color]::Transparent
        $hl.Dock = 'Fill'; $hl.Padding = New-Object System.Windows.Forms.Padding(8,0,0,0); $hl.TextAlign = 'MiddleLeft'; $hl.Cursor = 'Hand'
        $hp.Controls.Add($hl)
        $hp.Tag = $grp.key; $hl.Tag = $grp.key
        $hp.Add_Click($script:onSectionClick); $hl.Add_Click($script:onSectionClick)
        [void]$blocks.Add($hp)
        if ($collapsed) { continue }

        $sorted = @($members | Sort-Object @{ Expression = { Id-Key $_.id } }, @{ Expression = { $_.project } }, @{ Expression = { $_.id } })
        foreach ($r in $sorted) {
            $rowKey = Row-Key $r
            $expanded = $script:WrapAll -or [bool]$script:Expanded[$rowKey]
            $tag = if ($r.area) { $r.area } else { $r.project }

            $row = New-Object System.Windows.Forms.Panel
            $row.Dock = 'Top'; $row.BackColor = $cBg
            $row.Width = $cw   # set full width BEFORE sizing children so the task
                               # label's right-anchor margin is computed correctly
                               # (otherwise the default ~200px row width stretches it)

            [void](New-RowLabel $row ('#'+$r.id) 10 30 $cDim $fIdEn 'MiddleLeft')
            [void](New-RowLabel $row $G.dot      42 14 (StatusColor $r.status) $fDot 'MiddleCenter')
            $tl2 = New-RowLabel $row $tag        60 70 $cDim (FTag $tag) 'MiddleLeft'
            $tip.SetToolTip($tl2, $(if ($r.area) { '{0}  ({1})' -f $r.area, $r.project } else { $r.project }))

            $tl = New-Object System.Windows.Forms.Label
            $tl.Name = 'ltask'; $tl.Text = $r.task; $tl.ForeColor = $cText; $tl.Font = (FTask $r.task)
            $tl.BackColor = [System.Drawing.Color]::Transparent
            $tl.Location = New-Object System.Drawing.Point($taskX, 0); $tl.Anchor = $script:aTLR
            $row.Controls.Add($tl)
            $tip.SetToolTip($tl, ('#{0}  {1}' -f $r.id, $r.task))

            $row.Height = Set-TaskLabelState $tl $expanded $taskW

            $row.Tag = $rowKey; $row.Cursor = 'Hand'; $row.Add_Click($script:onRowClick); $row.ContextMenuStrip = $script:rowMenu
            foreach ($k in @($row.Controls)) { $k.Tag = $rowKey; $k.Cursor = 'Hand'; $k.Add_Click($script:onRowClick); $k.ContextMenuStrip = $script:rowMenu }
            [void]$blocks.Add($row)
        }
    }

    for ($i = $blocks.Count - 1; $i -ge 0; $i--) { $content.Controls.Add($blocks[$i]) }
    $content.ResumeLayout()
    try { $content.AutoScrollPosition = New-Object System.Drawing.Point((-$prevScroll.X), (-$prevScroll.Y)) } catch { }
}

function Show-Empty($msg) {
    $content.Controls.Clear()
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $msg; $l.ForeColor = $cDim; $l.Font = $fTaskEn
    $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'
    $content.Controls.Add($l)
}

# A small dark dialog that matches the panel (instead of the native gray
# MessageBox). Buttons use DialogResult so the modal closes itself -- no
# event-handler closures needed. Returns $true if the primary button was chosen.
function New-DlgButton($text, $result, $accent) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Font = $fTaskEn; $b.FlatStyle = 'Flat'
    $b.Size = New-Object System.Drawing.Size(84, 30)
    $b.DialogResult = $result
    if ($accent) {
        $b.BackColor = [System.Drawing.Color]::FromArgb(59,130,246); $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
    } else {
        $b.BackColor = $cBar; $b.ForeColor = $cText
        $b.FlatAppearance.BorderColor = $cBorder; $b.FlatAppearance.BorderSize = 1
    }
    return $b
}
function Show-Message($text, $titleText, [switch]$yesNo, $yesLabel = 'Open page') {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.FormBorderStyle = 'None'; $dlg.StartPosition = 'CenterScreen'
    $dlg.TopMost = $true; $dlg.ShowInTaskbar = $false; $dlg.BackColor = $cBg
    $dlg.ClientSize = New-Object System.Drawing.Size(330, 152)
    $dlg.Add_Paint({ param($s,$e)
        $pen = New-Object System.Drawing.Pen ($cBorder), 1
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1); $pen.Dispose() })

    $bar2 = New-Object System.Windows.Forms.Panel
    $bar2.Dock = 'Top'; $bar2.Height = 30; $bar2.BackColor = $cBar
    $ht = New-Object System.Windows.Forms.Label
    $ht.Text = $G.ring + '  ' + $titleText; $ht.ForeColor = $cText; $ht.Font = $fBar
    $ht.Dock = 'Fill'; $ht.Padding = New-Object System.Windows.Forms.Padding(10,0,0,0); $ht.TextAlign = 'MiddleLeft'
    $bar2.Controls.Add($ht); $dlg.Controls.Add($bar2)

    $msg = New-Object System.Windows.Forms.Label
    $msg.Text = $text; $msg.ForeColor = $cText; $msg.Font = $fTaskEn
    $msg.AutoSize = $false; $msg.Location = New-Object System.Drawing.Point(16, 44)
    $msg.Size = New-Object System.Drawing.Size(298, 56); $dlg.Controls.Add($msg)

    if ($yesNo) {
        $b1 = New-DlgButton $yesLabel ([System.Windows.Forms.DialogResult]::Yes) $true
        $b1.AutoSize = $true; $b1.Location = New-Object System.Drawing.Point(220, 110)
        $b2 = New-DlgButton 'Later'   ([System.Windows.Forms.DialogResult]::No)  $false
        $b2.Location = New-Object System.Drawing.Point(130, 110)
        $dlg.Controls.Add($b1); $dlg.Controls.Add($b2); $dlg.AcceptButton = $b1; $dlg.CancelButton = $b2
    } else {
        $b1 = New-DlgButton 'OK' ([System.Windows.Forms.DialogResult]::OK) $true
        $b1.Location = New-Object System.Drawing.Point(230, 110)
        $dlg.Controls.Add($b1); $dlg.AcceptButton = $b1
    }
    $r = $dlg.ShowDialog()
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Dark single-line input dialog. Returns the text, or $null if cancelled.
function Show-Input($promptText, $titleText, $default) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.FormBorderStyle = 'None'; $dlg.StartPosition = 'CenterScreen'
    $dlg.TopMost = $true; $dlg.ShowInTaskbar = $false; $dlg.BackColor = $cBg
    $dlg.ClientSize = New-Object System.Drawing.Size(380, 150)
    $dlg.Add_Paint({ param($s,$e)
        $pen = New-Object System.Drawing.Pen ($cBorder), 1
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1); $pen.Dispose() })

    $bar2 = New-Object System.Windows.Forms.Panel; $bar2.Dock = 'Top'; $bar2.Height = 30; $bar2.BackColor = $cBar
    $ht = New-Object System.Windows.Forms.Label; $ht.Text = $G.ring + '  ' + $titleText; $ht.ForeColor = $cText; $ht.Font = $fBar
    $ht.Dock = 'Fill'; $ht.Padding = New-Object System.Windows.Forms.Padding(10,0,0,0); $ht.TextAlign = 'MiddleLeft'
    $bar2.Controls.Add($ht); $dlg.Controls.Add($bar2)

    $pl = New-Object System.Windows.Forms.Label; $pl.Text = $promptText; $pl.ForeColor = $cDim; $pl.Font = $fTaskEn
    $pl.AutoSize = $false; $pl.Location = New-Object System.Drawing.Point(16, 40); $pl.Size = New-Object System.Drawing.Size(348, 18); $dlg.Controls.Add($pl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = [string]$default; $tb.BackColor = [System.Drawing.Color]::FromArgb(38,38,44); $tb.ForeColor = $cText
    $tb.BorderStyle = 'FixedSingle'; $tb.Font = (FTask ([string]$default))
    $tb.Location = New-Object System.Drawing.Point(16, 62); $tb.Size = New-Object System.Drawing.Size(348, 26)
    $dlg.Controls.Add($tb)

    $ok = New-DlgButton 'Save'   ([System.Windows.Forms.DialogResult]::OK)     $true
    $ok.Location = New-Object System.Drawing.Point(280, 108)
    $cn = New-DlgButton 'Cancel' ([System.Windows.Forms.DialogResult]::Cancel) $false
    $cn.Location = New-Object System.Drawing.Point(190, 108)
    $dlg.Controls.Add($ok); $dlg.Controls.Add($cn); $dlg.AcceptButton = $ok; $dlg.CancelButton = $cn
    $dlg.Add_Shown({ $tb.Focus(); $tb.SelectAll() })
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $tb.Text }
    return $null
}

# Dark dialog to create/edit a status: a name plus an optional color. Returns
# @{ name = <string>; color = <string> } (color is a palette name, a #rrggbb
# hex, or '' for auto-by-position), or $null if cancelled.
function Show-StatusEditor($titleText, $defaultName, $defaultColor) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.FormBorderStyle = 'None'; $dlg.StartPosition = 'CenterScreen'
    $dlg.TopMost = $true; $dlg.ShowInTaskbar = $false; $dlg.BackColor = $cBg
    $dlg.ClientSize = New-Object System.Drawing.Size(380, 222)
    $dlg.Add_Paint({ param($s,$e)
        $pen = New-Object System.Drawing.Pen ($cBorder), 1
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1); $pen.Dispose() })

    $bar2 = New-Object System.Windows.Forms.Panel; $bar2.Dock = 'Top'; $bar2.Height = 30; $bar2.BackColor = $cBar
    $ht = New-Object System.Windows.Forms.Label; $ht.Text = $G.ring + '  ' + $titleText; $ht.ForeColor = $cText; $ht.Font = $fBar
    $ht.Dock = 'Fill'; $ht.Padding = New-Object System.Windows.Forms.Padding(10,0,0,0); $ht.TextAlign = 'MiddleLeft'
    $bar2.Controls.Add($ht); $dlg.Controls.Add($bar2)

    $pl = New-Object System.Windows.Forms.Label; $pl.Text = 'Status name:'; $pl.ForeColor = $cDim; $pl.Font = $fTaskEn
    $pl.AutoSize = $false; $pl.Location = New-Object System.Drawing.Point(16, 40); $pl.Size = New-Object System.Drawing.Size(348, 18); $dlg.Controls.Add($pl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = [string]$defaultName; $tb.BackColor = [System.Drawing.Color]::FromArgb(38,38,44); $tb.ForeColor = $cText
    $tb.BorderStyle = 'FixedSingle'; $tb.Font = $fTaskEn
    $tb.Location = New-Object System.Drawing.Point(16, 62); $tb.Size = New-Object System.Drawing.Size(348, 26)
    $dlg.Controls.Add($tb)

    $cl = New-Object System.Windows.Forms.Label; $cl.Text = 'Color:'; $cl.ForeColor = $cDim; $cl.Font = $fTaskEn
    $cl.AutoSize = $false; $cl.Location = New-Object System.Drawing.Point(16, 96); $cl.Size = New-Object System.Drawing.Size(348, 18); $dlg.Controls.Add($cl)

    # Selection state: '' = auto, a palette name, or a '#rrggbb' hex.
    $script:nsSel = ([string]$defaultColor).Trim()
    $script:nsSwatches = @()

    $palNames = @('blue','amber','green','purple','red','cyan','pink','gray')
    $sw = 30; $gap = 6; $x0 = 16; $y0 = 116
    $i = 0
    foreach ($pn in $palNames) {
        $p = New-Object System.Windows.Forms.Panel
        $p.Size = New-Object System.Drawing.Size($sw, 22)
        $p.Location = New-Object System.Drawing.Point(($x0 + $i * ($sw + $gap)), $y0)
        $p.Tag = $pn; $p.Cursor = 'Hand'
        $tip.SetToolTip($p, $pn)
        $p.Add_Paint({
            param($s,$e)
            $col = $script:NamedColors[[string]$s.Tag]
            $br = New-Object System.Drawing.SolidBrush $col
            $e.Graphics.FillRectangle($br, 0, 0, $s.Width, $s.Height); $br.Dispose()
            if ($script:nsSel -eq [string]$s.Tag) {
                $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
                $e.Graphics.DrawRectangle($pen, 1, 1, $s.Width - 3, $s.Height - 3); $pen.Dispose()
            }
        })
        $p.Add_Click({ $script:nsSel = [string]$this.Tag; & $script:nsRefresh })
        $dlg.Controls.Add($p); $script:nsSwatches += $p
        $i++
    }

    $autoBtn = New-DlgButton 'Auto' ([System.Windows.Forms.DialogResult]::None) $false
    $autoBtn.Size = New-Object System.Drawing.Size(84, 28); $autoBtn.Location = New-Object System.Drawing.Point(16, 150)
    $tip.SetToolTip($autoBtn, 'Auto-color by position in the legend')
    $autoBtn.Add_Click({ $script:nsSel = ''; & $script:nsRefresh })
    $dlg.Controls.Add($autoBtn)

    $custBtn = New-DlgButton 'Custom...' ([System.Windows.Forms.DialogResult]::None) $false
    $custBtn.Size = New-Object System.Drawing.Size(96, 28); $custBtn.Location = New-Object System.Drawing.Point(108, 150)
    $custBtn.Add_Click({
        $cd = New-Object System.Windows.Forms.ColorDialog
        $cd.FullOpen = $true
        if ($script:nsSel -match '^#([0-9a-fA-F]{6})$') { $cd.Color = (Resolve-Color $script:nsSel) }
        if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:nsSel = ('#{0:x2}{1:x2}{2:x2}' -f $cd.Color.R, $cd.Color.G, $cd.Color.B)
            & $script:nsRefresh
        }
    })
    $dlg.Controls.Add($custBtn)

    # Refresh selection visuals: redraw swatches and highlight Auto / Custom.
    $script:nsRefresh = {
        foreach ($p in $script:nsSwatches) { $p.Invalidate() }
        $isAuto = ($script:nsSel -eq '')
        $isHex  = ($script:nsSel -match '^#([0-9a-fA-F]{6})$')
        $autoBtn.BackColor = $(if ($isAuto) { [System.Drawing.Color]::FromArgb(59,130,246) } else { $cBar })
        $autoBtn.ForeColor = $(if ($isAuto) { [System.Drawing.Color]::White } else { $cText })
        if ($isHex) {
            $c = Resolve-Color $script:nsSel
            $custBtn.BackColor = $c
            $custBtn.ForeColor = $(if (($c.R*0.299 + $c.G*0.587 + $c.B*0.114) -gt 150) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White })
            $custBtn.Text = $script:nsSel
        } else {
            $custBtn.BackColor = $cBar; $custBtn.ForeColor = $cText; $custBtn.Text = 'Custom...'
        }
    }

    $ok = New-DlgButton 'Save'   ([System.Windows.Forms.DialogResult]::OK)     $true
    $ok.Location = New-Object System.Drawing.Point(280, 184)
    $cn = New-DlgButton 'Cancel' ([System.Windows.Forms.DialogResult]::Cancel) $false
    $cn.Location = New-Object System.Drawing.Point(190, 184)
    $dlg.Controls.Add($ok); $dlg.Controls.Add($cn); $dlg.AcceptButton = $ok; $dlg.CancelButton = $cn

    $dlg.Add_Shown({ $tb.Focus(); $tb.SelectAll(); & $script:nsRefresh })
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return @{ name = $tb.Text; color = $script:nsSel }
    }
    return $null
}

# Atomic UTF-8 (no BOM) write: temp file + Replace, so a crash can't leave the
# file half-written. Returns $false if the file is busy / write fails.
function Write-FileAtomic($path, $text) {
    $tmp = $null
    try {
        $full = [System.IO.Path]::GetFullPath($path)   # normalize (forward slashes -> backslashes)
        $enc  = New-Object System.Text.UTF8Encoding($false)
        $tmp  = $full + '.tttmp'
        [System.IO.File]::WriteAllText($tmp, $text, $enc)   # fully write temp first
        [System.IO.File]::Copy($tmp, $full, $true)          # then overwrite in one call
        [System.IO.File]::Delete($tmp)
        return $true
    } catch {
        try { if ($tmp -and (Test-Path $tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
        return $false
    }
}

function Get-ProjectName($path) {
    return [System.IO.Path]::GetFileNameWithoutExtension($path)
}

function Combined-Mtime {
    $s = ''
    foreach ($f in $script:Files) { try { $s += [string](Get-Item $f -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { $s += '0' }; $s += '|' }
    return $s
}

function Update-Now {
    param([switch]$force)

    if ($script:Files.Count -eq 0) {
        Show-Empty ('No task files loaded.' + "`n`n" + 'Menu (' + $G.menu + ')  ->  Add task file(s)...')
        $script:LastMtime = $null; $script:LastSig = '__none__'
        return
    }

    $mt = Combined-Mtime
    if (-not $force -and $null -ne $script:LastMtime -and $mt -eq $script:LastMtime) { return }

    # Read every file once (tolerant); skip the whole round if any is locked.
    $entries = @()
    foreach ($f in $script:Files) {
        if (-not (Test-Path $f)) { continue }
        $raw = Read-TasksFile $f
        if ($null -eq $raw) { return }
        $entries += @{ project = (Get-ProjectName $f); raw = $raw; path = $f }
    }

    Build-Statuses (@($entries | ForEach-Object { $_.raw }))
    $script:LastMtime = $mt
    $tip.SetToolTip($title, ($script:Files -join "`n"))

    if ($script:Statuses.Count -eq 0) {
        $script:LastSig = '__nolegend__'
        Show-Empty ('No status legend found.' + "`n`n" + "Add a '## Status legend' section to a tracked file (see PROMPT.md).")
        return
    }

    $all = @()
    foreach ($e in $entries) { $all += Parse-File $e.raw $e.project $e.path }

    # Append an "Other" status if any task didn't match a legend status.
    if ((@($all | Where-Object { $_.status -eq '__other__' }).Count -gt 0) -and -not (Get-Status '__other__')) {
        $script:Statuses += [pscustomobject]@{ key = '__other__'; name = 'Other'; emoji = ''; color = $null; colorObj = $cOther }
    }

    $statusSig = ($script:Statuses | ForEach-Object { $_.key + ':' + $_.colorObj.ToArgb() }) -join ','
    $taskSig   = ($all | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.project,$_.id,$_.status,$_.area,$_.task }) -join "`n"
    $sig = $statusSig + "`n" + $taskSig
    if (-not $force -and $sig -eq $script:LastSig) { return }
    $script:LastSig = $sig

    if ($all.Count -eq 0) { Show-Empty 'No tasks found in the loaded file(s).'; return }
    Render-List $all
}

# ------------------------------------------------------------- files --------
function Add-Files {
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Markdown / text (*.md;*.markdown;*.txt)|*.md;*.markdown;*.txt|All files (*.*)|*.*'
    $ofd.Multiselect = $true
    $ofd.Title = 'Choose task file(s) to track'
    if ($script:Files.Count -gt 0) { try { $ofd.InitialDirectory = Split-Path $script:Files[0] -Parent } catch { } }
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($f in $ofd.FileNames) { if ($script:Files -notcontains $f) { $script:Files = @($script:Files) + $f } }
        $script:LastMtime = $null; $script:LastSig = '__refile__'
        Save-Config; Update-Now -force
    }
}

function Remove-FilePath($path) {
    $script:Files = @($script:Files | Where-Object { $_ -ne $path })
    $script:LastMtime = $null; $script:LastSig = '__refile__'
    Save-Config; Update-Now -force
}

# ------------------------------------------------- roll up / collapse -------
function Set-Rolled($rolled) {
    $script:Rolled = [bool]$rolled
    if ($script:Rolled) {
        $content.Visible = $false; $grip.Visible = $false
        $form.Height = $TitleH + 1
    } else {
        $content.Visible = $true; $grip.Visible = $true
        $form.Height = [Math]::Max($MinH, $script:PosH)
    }
    $btnRoll.Text = $(if ($script:Rolled) { $G.triDown } else { $G.rollUp })
    $tip.SetToolTip($btnRoll, $(if ($script:Rolled) { 'Expand' } else { 'Collapse to title bar' }))
    Save-Config
}
function Toggle-Roll { Set-Rolled (-not $script:Rolled) }

# Wrap (expand) every task title to its full text in one click, or collapse them
# all back. When on, every row wraps regardless of individual click-to-expand.
function Set-WrapAll($on) {
    $script:WrapAll = [bool]$on
    if (-not $script:WrapAll) { $script:Expanded = @{} }   # turning off collapses all
    Save-Config
    Update-Now -force
}
function Toggle-WrapAll { Set-WrapAll (-not $script:WrapAll) }

# ------------------------------------------------------- update check -------
function Open-Repo { try { Start-Process $RepoUrl } catch { } }

# Compare versions: prefer dotted-version ordering (1.2.0 > 1.1.9); fall back to
# integer, then to "any difference".
function Is-Newer($remote, $local) {
    try { return ([version]([string]$remote).Trim() -gt [version]([string]$local).Trim()) } catch { }
    $r = 0; $l = 0
    if ([int]::TryParse([string]$remote, [ref]$r) -and [int]::TryParse([string]$local, [ref]$l)) { return ($r -gt $l) }
    return ([bool]$remote -and ([string]$remote -ne [string]$local))
}

function Update-UpdateUI {
    $dotUpd.Visible = $script:UpdateAvailable
    if ($script:UpdateAvailable) { $tip.SetToolTip($dotUpd, ('Update available (v{0}; you have v{1}) - click to update' -f $script:RemoteVersion, $script:LocalVersion)) }
}

# Synchronous fetch (used for the user-initiated update download).
function Fetch-Url($url) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [System.Net.HttpWebRequest]::Create($url); $req.Timeout = 15000; $req.ReadWriteTimeout = 15000; $req.UserAgent = 'TasksTracker'
        $resp = $req.GetResponse(); $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close(); return $t
    } catch { return $null }
}

# Download the latest script, verify it parses, overwrite this script + VERSION,
# relaunch a fresh instance, and close this one. config.json (files/position) is
# untouched so the new instance comes back the same.
function Do-SelfUpdate {
    $new = Fetch-Url $ScriptUrl
    if (-not $new) { Show-Message 'Download failed (offline?).' 'Tasks Tracker' | Out-Null; return }
    $self = $PSCommandPath
    if (-not $self) { Show-Message 'Cannot locate the script to update.' 'Tasks Tracker' | Out-Null; return }
    $tmp = (Join-Path $PSScriptRoot '_update.tmp.ps1')
    try {
        [System.IO.File]::WriteAllText($tmp, $new, (New-Object System.Text.UTF8Encoding($false)))
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs) | Out-Null
        if ($errs -and $errs.Count -gt 0) { [System.IO.File]::Delete($tmp); Show-Message 'The downloaded update looked invalid; kept the current version.' 'Tasks Tracker' | Out-Null; return }
        [System.IO.File]::Copy($tmp, ([System.IO.Path]::GetFullPath($self)), $true)
        [System.IO.File]::Delete($tmp)
    } catch {
        try { if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) } } catch { }
        Show-Message 'Could not write the update (file busy?).' 'Tasks Tracker' | Out-Null; return
    }
    $rv = Fetch-Url $VersionUrl
    if ($rv) { try { Write-FileAtomic (Join-Path $PSScriptRoot 'VERSION') (([string]$rv).Trim()) | Out-Null } catch { } }
    try { Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Sta','-WindowStyle','Hidden','-File',$self } catch { }
    $form.Close()
}

# Offer to download + restart when an update is available.
function Update-Flow {
    $msg = ('An update is available (v{0}; you have v{1}).{2}Download it and restart now?' -f $script:RemoteVersion, $script:LocalVersion, "`n")
    if (Show-Message $msg 'Tasks Tracker' -yesNo -yesLabel 'Update now') { Do-SelfUpdate }
}

# Fetch the remote VERSION in a separate runspace so the UI never blocks; the
# timer polls for completion. Offline / failure -> no flag, no error (unless manual).
function Start-UpdateCheck { param([switch]$manual)
    if ($script:updHandle) { if ($manual) { $script:updManual = $true }; return }
    $script:updManual = [bool]$manual
    try {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($url)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $req = [System.Net.HttpWebRequest]::Create($url)
                $req.Timeout = 6000; $req.ReadWriteTimeout = 6000; $req.UserAgent = 'TasksTracker'
                $resp = $req.GetResponse(); $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
                return ([string]$t).Trim()
            } catch { return $null }
        }).AddArgument($VersionUrl)
        $script:updPS = $ps
        $script:updHandle = $ps.BeginInvoke()
    } catch { $script:updPS = $null; $script:updHandle = $null; $script:updManual = $false }
}

function Poll-UpdateCheck {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not $script:updHandle -and (($now - $script:lastUpdateCheck) -gt 86400)) { Start-UpdateCheck }  # daily
    if ($script:updHandle -and $script:updHandle.IsCompleted) {
        $remote = $null
        try { $remote = @($script:updPS.EndInvoke($script:updHandle)) | Where-Object { $_ } | Select-Object -Last 1 } catch { }
        try { $script:updPS.Dispose() } catch { }
        $script:updPS = $null; $script:updHandle = $null
        $script:lastUpdateCheck = $now; Save-Config
        $manual = $script:updManual; $script:updManual = $false
        if ($remote) { $script:RemoteVersion = [string]$remote; $script:UpdateAvailable = (Is-Newer $remote $script:LocalVersion) }
        Update-UpdateUI
        if ($manual) {
            if (-not $remote) {
                Show-Message 'Could not check for updates (offline?).' 'Tasks Tracker' | Out-Null
            } elseif ($script:UpdateAvailable) {
                Update-Flow
            } else {
                Show-Message ('You are on the latest version (v{0}).' -f $script:LocalVersion) 'Tasks Tracker' | Out-Null
            }
        }
    }
}

# ------------------------------------------------------------- buttons ------
$btnRefresh.Add_Click({ Update-Now -force })
$btnClose.Add_Click({ $form.Close() })
$btnRoll.Add_Click({ Toggle-Roll })
$dotUpd.Add_Click({ Update-Flow })

$btnMenu.Add_Click({
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.BackColor = $cBar; $menu.ForeColor = $cText; $menu.ShowImageMargin = $false

    $miAdd = New-Object System.Windows.Forms.ToolStripMenuItem('Add task file(s)...')
    $miAdd.ForeColor = $cText
    $miAdd.Add_Click({ Add-Files })
    [void]$menu.Items.Add($miAdd)

    if ($script:Files.Count -gt 0) {
        $miRemove = New-Object System.Windows.Forms.ToolStripMenuItem('Remove file')
        $miRemove.ForeColor = $cText
        $miRemove.DropDown.BackColor = $cBar; $miRemove.DropDown.ForeColor = $cText; $miRemove.DropDown.ShowImageMargin = $false
        $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem('Open file location')
        $miOpen.ForeColor = $cText
        $miOpen.DropDown.BackColor = $cBar; $miOpen.DropDown.ForeColor = $cText; $miOpen.DropDown.ShowImageMargin = $false
        foreach ($f in $script:Files) {
            $nm = Split-Path $f -Leaf
            $ri = New-Object System.Windows.Forms.ToolStripMenuItem($nm); $ri.ForeColor = $cText; $ri.Tag = $f
            $ri.Add_Click({ Remove-FilePath $this.Tag })
            [void]$miRemove.DropDownItems.Add($ri)
            $oi = New-Object System.Windows.Forms.ToolStripMenuItem($nm); $oi.ForeColor = $cText; $oi.Tag = $f
            $oi.Add_Click({ try { Start-Process explorer.exe ('/select,"{0}"' -f $this.Tag) } catch { } })
            [void]$miOpen.DropDownItems.Add($oi)
        }
        [void]$menu.Items.Add($miRemove)
        [void]$menu.Items.Add($miOpen)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExpand = New-Object System.Windows.Forms.ToolStripMenuItem('Expand all sections'); $miExpand.ForeColor = $cText
    $miExpand.Add_Click({ foreach ($s in $script:Statuses) { $script:Collapsed[$s.key] = $false }; Save-Config; Update-Now -force })
    [void]$menu.Items.Add($miExpand)
    $miCollapse = New-Object System.Windows.Forms.ToolStripMenuItem('Collapse all sections'); $miCollapse.ForeColor = $cText
    $miCollapse.Add_Click({ foreach ($s in $script:Statuses) { $script:Collapsed[$s.key] = $true }; Save-Config; Update-Now -force })
    [void]$menu.Items.Add($miCollapse)

    $miWrap = New-Object System.Windows.Forms.ToolStripMenuItem($(if ($script:WrapAll) { 'Unwrap all titles' } else { 'Wrap all titles' })); $miWrap.ForeColor = $cText
    $miWrap.Add_Click({ Toggle-WrapAll })
    [void]$menu.Items.Add($miWrap)

    $miManage = New-Object System.Windows.Forms.ToolStripMenuItem('Manage statuses...'); $miManage.ForeColor = $cText
    $miManage.Add_Click({ Show-ManageStatuses })
    [void]$menu.Items.Add($miManage)

    $miRoll = New-Object System.Windows.Forms.ToolStripMenuItem($(if ($script:Rolled) { 'Expand from title bar' } else { 'Collapse to title bar' })); $miRoll.ForeColor = $cText
    $miRoll.Add_Click({ Toggle-Roll })
    [void]$menu.Items.Add($miRoll)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    if ($script:UpdateAvailable) {
        $miUpd = New-Object System.Windows.Forms.ToolStripMenuItem(('Update available (v{0}) - update now' -f $script:RemoteVersion))
        $miUpd.ForeColor = [System.Drawing.Color]::FromArgb(245,158,11)
        $miUpd.Add_Click({ Update-Flow })
        [void]$menu.Items.Add($miUpd)
    }
    $miCheck = New-Object System.Windows.Forms.ToolStripMenuItem('Check for updates'); $miCheck.ForeColor = $cText
    $miCheck.Add_Click({ Start-UpdateCheck -manual })
    [void]$menu.Items.Add($miCheck)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miQuit = New-Object System.Windows.Forms.ToolStripMenuItem('Close panel'); $miQuit.ForeColor = $cText
    $miQuit.Add_Click({ $form.Close() })
    [void]$menu.Items.Add($miQuit)

    $menu.Show($btnMenu, (New-Object System.Drawing.Point(0, $TitleH)))
})

# --------------------------------------------------- edit / write-back ------
function Find-Rec($rowKey) { foreach ($r in $script:LastRecs) { if ((Row-Key $r) -eq $rowKey) { return $r } }; return $null }

function Save-FileChange($path, $newText) {
    if (Write-FileAtomic $path $newText) { $script:LastMtime = $null; $script:LastSig = '__edited__'; Update-Now -force }
    else { Show-Message 'Could not save (file busy? try again).' 'Tasks Tracker' | Out-Null }
}
function Do-EditTask($rec) {
    if (-not $rec) { return }
    $new = Show-Input 'Edit task title:' 'Edit task' $rec.task
    if ($null -eq $new) { return }
    $new = $new.Trim(); if (-not $new) { return }
    $raw = Read-TasksFile $rec.file
    if ($null -eq $raw) { Show-Message 'File is busy, try again.' 'Tasks Tracker' | Out-Null; return }
    Save-FileChange $rec.file (Set-TaskTitleText $raw $rec.area $rec.id $new)
}
function Do-ChangeStatus($rec, $statusName, $isNew, $color = '') {
    if (-not $rec) { return }
    $raw = Read-TasksFile $rec.file
    if ($null -eq $raw) { Show-Message 'File is busy, try again.' 'Tasks Tracker' | Out-Null; return }
    if ($isNew) { $raw = Add-LegendStatusText $raw $statusName $color }
    Save-FileChange $rec.file (Move-TaskStatusText $raw $rec.area $rec.id $statusName)
}
function Do-NewStatus($rec) {
    if (-not $rec) { return }
    $res = Show-StatusEditor 'New status' '' ''
    if ($null -eq $res) { return }
    $name = ([string]$res.name).Trim(); if (-not $name) { return }
    Do-ChangeStatus $rec $name $true $res.color
}

# Apply a managed status model across every tracked file. $items is the final
# ordered list (@{ name; color; origName; origColor }, origName=$null for new);
# $origNames is the full set of names before editing (to detect deletions).
function Save-StatusModel($items, $origNames) {
    $kept = @{}
    foreach ($it in $items) { if ($it.origName) { $kept[$it.origName.ToLower()] = $true } }
    $deletions = @($origNames | Where-Object { -not $kept.ContainsKey(([string]$_).ToLower()) })
    $order = @($items | ForEach-Object { $_.name })

    $errors = 0
    foreach ($f in $script:Files) {
        $raw = Read-TasksFile $f
        if ($null -eq $raw) { $errors++; continue }
        $t = $raw
        foreach ($d in $deletions) { $t = Remove-LegendStatusText $t $d }
        foreach ($it in $items) {
            if ($it.origName) {
                if ($it.name -ne $it.origName) { $t = Rename-LegendStatusText $t $it.origName $it.name }
                if (([string]$it.color) -ne ([string]$it.origColor)) { $t = Set-LegendColorText $t $it.name $it.color }
            }
        }
        foreach ($it in $items) { if (-not $it.origName) { $t = Add-LegendStatusText $t $it.name $it.color } }
        $t = Reorder-LegendText $t $order
        if ($t -ne $raw) { if (-not (Write-FileAtomic $f $t)) { $errors++ } }
    }
    $script:LastMtime = $null; $script:LastSig = '__statusmgr__'; Update-Now -force
    if ($errors) { Show-Message 'Some files were busy; not all changes were saved.' 'Tasks Tracker' | Out-Null }
}

# Settings dialog to manage all statuses: add / delete / edit (name + color) /
# reorder. Deleting a status that has tasks asks first; its tasks fall into the
# no-status ("Other") group. Changes are applied to every tracked file on Save.
function Show-ManageStatuses {
    if ($script:Statuses.Count -eq 0) {
        Show-Message ('No statuses to manage.' + "`n`n" + 'Add a "## Status legend" to a tracked file first.') 'Tasks Tracker' | Out-Null
        return
    }
    $orig = @($script:Statuses | Where-Object { $_.key -ne '__other__' })
    $origNames = @($orig | ForEach-Object { $_.name })
    $counts = @{}
    foreach ($rr in $script:LastRecs) { $k = $rr.status; if (-not $counts.ContainsKey($k)) { $counts[$k] = 0 }; $counts[$k]++ }

    $script:msItems = @()
    foreach ($s in $orig) {
        $c = $(if ($counts.ContainsKey($s.key)) { $counts[$s.key] } else { 0 })
        $script:msItems += [pscustomobject]@{ name = $s.name; color = ([string]$s.color); origName = $s.name; origColor = ([string]$s.color); count = $c }
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.FormBorderStyle = 'None'; $dlg.StartPosition = 'CenterScreen'
    $dlg.TopMost = $true; $dlg.ShowInTaskbar = $false; $dlg.BackColor = $cBg
    $dlg.ClientSize = New-Object System.Drawing.Size(420, 360)
    $dlg.Add_Paint({ param($s,$e)
        $pen = New-Object System.Drawing.Pen ($cBorder), 1
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1); $pen.Dispose() })

    $bar2 = New-Object System.Windows.Forms.Panel; $bar2.Dock = 'Top'; $bar2.Height = 30; $bar2.BackColor = $cBar
    $ht = New-Object System.Windows.Forms.Label; $ht.Text = $G.ring + '  Manage statuses'; $ht.ForeColor = $cText; $ht.Font = $fBar
    $ht.Dock = 'Fill'; $ht.Padding = New-Object System.Windows.Forms.Padding(10,0,0,0); $ht.TextAlign = 'MiddleLeft'
    $bar2.Controls.Add($ht); $dlg.Controls.Add($bar2)

    $list = New-Object System.Windows.Forms.Panel
    $list.Location = New-Object System.Drawing.Point(10, 40); $list.Size = New-Object System.Drawing.Size(400, 256)
    $list.BackColor = $cBg; $list.AutoScroll = $true; $dlg.Controls.Add($list)

    $mkBtn = {
        param($txt, $w)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $txt; $b.Font = $fTaskEn; $b.FlatStyle = 'Flat'; $b.Size = New-Object System.Drawing.Size($w, 24)
        $b.BackColor = $cBar; $b.ForeColor = $cText; $b.FlatAppearance.BorderColor = $cBorder; $b.FlatAppearance.BorderSize = 1
        return $b
    }
    $nameTaken = {
        param($nm, $exceptIdx)
        for ($j = 0; $j -lt $script:msItems.Count; $j++) {
            if ($j -ne $exceptIdx -and $script:msItems[$j].name.ToLower() -eq ([string]$nm).ToLower()) { return $true }
        }
        return $false
    }

    $script:msRender = {
        $list.Controls.Clear()
        for ($i = 0; $i -lt $script:msItems.Count; $i++) {
            $it = $script:msItems[$i]
            $y = $i * 32 + 2

            $sw = New-Object System.Windows.Forms.Panel
            $sw.Size = New-Object System.Drawing.Size(16, 16); $sw.Location = New-Object System.Drawing.Point(6, ($y + 5))
            $col = $(if ($it.color) { Resolve-Color $it.color } else { $null })
            if (-not $col) { $col = $script:Palette[$i % $script:Palette.Count] }
            $sw.BackColor = $col; $list.Controls.Add($sw)

            $nl = New-Object System.Windows.Forms.Label
            $nl.Text = $it.name; $nl.ForeColor = $cText; $nl.Font = (FTask $it.name)
            $nl.AutoSize = $false; $nl.TextAlign = 'MiddleLeft'
            $nl.Location = New-Object System.Drawing.Point(30, $y); $nl.Size = New-Object System.Drawing.Size(150, 26)
            $list.Controls.Add($nl)

            $cl = New-Object System.Windows.Forms.Label
            $cl.Text = $(if ($it.count -gt 0) { "($($it.count))" } else { '' }); $cl.ForeColor = $cDim; $cl.Font = $fTime
            $cl.AutoSize = $false; $cl.TextAlign = 'MiddleLeft'
            $cl.Location = New-Object System.Drawing.Point(182, $y); $cl.Size = New-Object System.Drawing.Size(38, 26)
            $list.Controls.Add($cl)

            $up = & $mkBtn $G.rollUp 26; $up.Location = New-Object System.Drawing.Point(222, ($y + 1)); $up.Tag = $i
            $up.Enabled = ($i -gt 0)
            $up.Add_Click({ $i = [int]$this.Tag; $tmp = $script:msItems[$i-1]; $script:msItems[$i-1] = $script:msItems[$i]; $script:msItems[$i] = $tmp; & $script:msRender })
            $list.Controls.Add($up)

            $dn = & $mkBtn $G.triDown 26; $dn.Location = New-Object System.Drawing.Point(250, ($y + 1)); $dn.Tag = $i
            $dn.Enabled = ($i -lt $script:msItems.Count - 1)
            $dn.Add_Click({ $i = [int]$this.Tag; $tmp = $script:msItems[$i+1]; $script:msItems[$i+1] = $script:msItems[$i]; $script:msItems[$i] = $tmp; & $script:msRender })
            $list.Controls.Add($dn)

            $ed = & $mkBtn 'Edit' 46; $ed.Location = New-Object System.Drawing.Point(280, ($y + 1)); $ed.Tag = $i
            $ed.Add_Click({
                $i = [int]$this.Tag; $it = $script:msItems[$i]
                $res = Show-StatusEditor 'Edit status' $it.name $it.color
                if ($null -eq $res) { return }
                $nm = ([string]$res.name).Trim(); if (-not $nm) { return }
                if (& $script:msNameTaken $nm $i) { Show-Message ("A status named '$nm' already exists.") 'Tasks Tracker' | Out-Null; return }
                $it.name = $nm; $it.color = $res.color; & $script:msRender
            })
            $list.Controls.Add($ed)

            $del = & $mkBtn 'Del' 36; $del.Location = New-Object System.Drawing.Point(330, ($y + 1)); $del.Tag = $i
            $del.ForeColor = [System.Drawing.Color]::FromArgb(248,113,113)
            $del.Add_Click({
                $i = [int]$this.Tag; $it = $script:msItems[$i]
                if ($it.count -gt 0) {
                    $ok = Show-Message ("'$($it.name)' has $($it.count) task(s); they'll move to no status.`n`nDelete this status?") 'Delete status' -yesNo -yesLabel 'Delete'
                    if (-not $ok) { return }
                }
                $script:msItems = @($script:msItems | Where-Object { $_ -ne $it })
                & $script:msRender
            })
            $list.Controls.Add($del)
        }
    }
    # Expose helpers used inside the (script-scoped) render handlers.
    $script:msNameTaken = $nameTaken

    $addBtn = & $mkBtn 'Add status...' 110; $addBtn.Size = New-Object System.Drawing.Size(110, 28)
    $addBtn.Location = New-Object System.Drawing.Point(10, 308)
    $addBtn.Add_Click({
        $res = Show-StatusEditor 'Add status' '' ''
        if ($null -eq $res) { return }
        $nm = ([string]$res.name).Trim(); if (-not $nm) { return }
        if (& $script:msNameTaken $nm -1) { Show-Message ("A status named '$nm' already exists.") 'Tasks Tracker' | Out-Null; return }
        $script:msItems = @($script:msItems) + [pscustomobject]@{ name = $nm; color = $res.color; origName = $null; origColor = ''; count = 0 }
        & $script:msRender
    })
    $dlg.Controls.Add($addBtn)

    $save = New-DlgButton 'Save'   ([System.Windows.Forms.DialogResult]::OK)     $true
    $save.Location = New-Object System.Drawing.Point(326, 308)
    $cancel = New-DlgButton 'Cancel' ([System.Windows.Forms.DialogResult]::Cancel) $false
    $cancel.Location = New-Object System.Drawing.Point(236, 308)
    $dlg.Controls.Add($save); $dlg.Controls.Add($cancel); $dlg.AcceptButton = $save; $dlg.CancelButton = $cancel

    $dlg.Add_Shown({ & $script:msRender })
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Save-StatusModel $script:msItems $origNames
    }
}

# Shared right-click menu for task rows; rebuilt each time it opens from the
# row's record (the row/labels carry the row key on .Tag; SourceControl tells
# us which one was clicked).
$script:rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:rowMenu.BackColor = $cBar; $script:rowMenu.ForeColor = $cText; $script:rowMenu.ShowImageMargin = $false
$script:rowMenu.Add_Opening({
    $rk = $null; try { $rk = [string]$script:rowMenu.SourceControl.Tag } catch { }
    $script:rowMenu.Items.Clear()
    $rec = Find-Rec $rk
    if (-not $rec) { $n = New-Object System.Windows.Forms.ToolStripMenuItem('(no task)'); $n.Enabled = $false; [void]$script:rowMenu.Items.Add($n); return }

    $miEdit = New-Object System.Windows.Forms.ToolStripMenuItem('Edit task...'); $miEdit.ForeColor = $cText; $miEdit.Tag = $rk
    $miEdit.Add_Click({ Do-EditTask (Find-Rec $this.Tag) })
    [void]$script:rowMenu.Items.Add($miEdit)

    $miStatus = New-Object System.Windows.Forms.ToolStripMenuItem('Status'); $miStatus.ForeColor = $cText
    $miStatus.DropDown.BackColor = $cBar; $miStatus.DropDown.ForeColor = $cText; $miStatus.DropDown.ShowImageMargin = $false
    foreach ($s in $script:Statuses) {
        if ($s.key -eq '__other__') { continue }
        $mark = $(if ($s.key -eq $rec.status) { [char]0x2713 + ' ' } else { '' })
        $si = New-Object System.Windows.Forms.ToolStripMenuItem($mark + $s.name); $si.ForeColor = $cText; $si.Tag = $rk; $si.Name = $s.name
        $si.Add_Click({ Do-ChangeStatus (Find-Rec $this.Tag) $this.Name $false })
        [void]$miStatus.DropDownItems.Add($si)
    }
    [void]$miStatus.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miNew = New-Object System.Windows.Forms.ToolStripMenuItem('New status...'); $miNew.ForeColor = $cText; $miNew.Tag = $rk
    $miNew.Add_Click({ Do-NewStatus (Find-Rec $this.Tag) })
    [void]$miStatus.DropDownItems.Add($miNew)
    [void]$script:rowMenu.Items.Add($miStatus)
})

# ------------------------------------------------------------- dragging -----
$script:dragging = $false
$script:dragOff  = New-Object System.Drawing.Point(0,0)
$startDrag = { param($s,$e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:dragging = $true; $script:dragOff = New-Object System.Drawing.Point($e.X, $e.Y) } }
$doDrag = { param($s,$e) if ($script:dragging) { $p = [System.Windows.Forms.Cursor]::Position; $form.Location = New-Object System.Drawing.Point(($p.X - $script:dragOff.X), ($p.Y - $script:dragOff.Y)) } }
$endDrag = { param($s,$e) if ($script:dragging) { $script:dragging = $false; $script:PosX = $form.Location.X; $script:PosY = $form.Location.Y; Save-Config } }
foreach ($ctl in @($bar, $title)) { $ctl.Add_MouseDown($startDrag); $ctl.Add_MouseMove($doDrag); $ctl.Add_MouseUp($endDrag) }
# Double-click the title bar to roll up / down.
$bar.Add_DoubleClick({ Toggle-Roll }); $title.Add_DoubleClick({ Toggle-Roll })

# ------------------------------------------------------------- resizing -----
$script:rsz = $false
$grip.Add_MouseDown({ param($s,$e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:rsz = $true; $script:rszStart = [System.Windows.Forms.Cursor]::Position; $script:rszW = $form.Width; $script:rszH = $form.Height } })
$grip.Add_MouseMove({
    param($s,$e)
    if ($script:rsz) {
        $p = [System.Windows.Forms.Cursor]::Position
        $nw = $script:rszW + ($p.X - $script:rszStart.X); $nh = $script:rszH + ($p.Y - $script:rszStart.Y)
        if ($nw -lt $MinW) { $nw = $MinW }; if ($nh -lt $MinH) { $nh = $MinH }
        $form.Width = $nw; $form.Height = $nh
    }
})
$grip.Add_MouseUp({
    param($s,$e)
    if ($script:rsz) {
        $script:rsz = $false; $script:PosW = $form.Width; $script:PosH = $form.Height
        Save-Config
        if ($script:LastRecs) { Render-List $script:LastRecs }
    }
})

# ---- resize from any edge / corner ----
# The form exposes a thin border band (via $form.Padding) that no child control
# covers, so it receives mouse events there. We classify which edge(s) the cursor
# is near and resize the window accordingly, mirroring the corner grip.
$script:edgeRsz  = $false
$script:edgeZone = ''
$EdgeM = 8   # px from an edge that counts as a resize grab

function Get-EdgeZone($e) {
    $w = $form.ClientSize.Width; $h = $form.ClientSize.Height
    $l = $e.X -le $EdgeM; $r = $e.X -ge ($w - $EdgeM)
    $t = $e.Y -le $EdgeM; $b = $e.Y -ge ($h - $EdgeM)
    $z = ''
    if     ($t) { $z += 'T' } elseif ($b) { $z += 'B' }
    if     ($l) { $z += 'L' } elseif ($r) { $z += 'R' }
    return $z
}
function Cursor-ForZone($z) {
    switch ($z) {
        'T'  { 'SizeNS' }   'B'  { 'SizeNS' }
        'L'  { 'SizeWE' }   'R'  { 'SizeWE' }
        'TL' { 'SizeNWSE' } 'BR' { 'SizeNWSE' }
        'TR' { 'SizeNESW' } 'BL' { 'SizeNESW' }
        default { 'Default' }
    }
}
$form.Add_MouseDown({
    param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $z = Get-EdgeZone $e
        if ($z -ne '') {
            $script:edgeRsz = $true; $script:edgeZone = $z
            $script:rszStart = [System.Windows.Forms.Cursor]::Position
            $script:rszX = $form.Location.X; $script:rszY = $form.Location.Y
            $script:rszW = $form.Width;      $script:rszH = $form.Height
        }
    }
})
$form.Add_MouseMove({
    param($s,$e)
    if ($script:edgeRsz) {
        $p = [System.Windows.Forms.Cursor]::Position
        $dx = $p.X - $script:rszStart.X; $dy = $p.Y - $script:rszStart.Y
        $x = $script:rszX; $y = $script:rszY; $w = $script:rszW; $h = $script:rszH
        if ($script:edgeZone.Contains('R')) { $w = $script:rszW + $dx }
        if ($script:edgeZone.Contains('B')) { $h = $script:rszH + $dy }
        if ($script:edgeZone.Contains('L')) { $w = $script:rszW - $dx; $x = $script:rszX + $dx }
        if ($script:edgeZone.Contains('T')) { $h = $script:rszH - $dy; $y = $script:rszY + $dy }
        if ($w -lt $MinW) { if ($script:edgeZone.Contains('L')) { $x -= ($MinW - $w) }; $w = $MinW }
        if ($h -lt $MinH) { if ($script:edgeZone.Contains('T')) { $y -= ($MinH - $h) }; $h = $MinH }
        $form.SetBounds($x, $y, $w, $h)
    } else {
        $form.Cursor = Cursor-ForZone (Get-EdgeZone $e)
    }
})
$form.Add_MouseUp({
    param($s,$e)
    if ($script:edgeRsz) {
        $script:edgeRsz = $false
        $script:PosX = $form.Location.X; $script:PosY = $form.Location.Y
        $script:PosW = $form.Width;      $script:PosH = $form.Height
        Save-Config
        if ($script:LastRecs) { Render-List $script:LastRecs }
    }
})
$form.Add_MouseLeave({ if (-not $script:edgeRsz) { $form.Cursor = 'Default' } })

# ------------------------------------------------------------- timer --------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Now; Poll-UpdateCheck })
$timer.Start()

# Single instance: when a new copy launches, close any previous one so only the
# newest window stays. We record our PID next to the script; a new instance reads
# it, verifies that process is really one of ours (by command line, falling back
# to process name), and closes it (graceful, then forced).
function Enforce-SingleInstance {
    try {
        if (Test-Path $PidFile) {
            $old = 0
            if ([int]::TryParse((([string](Get-Content $PidFile -Raw)).Trim()), [ref]$old) -and $old -ne $PID) {
                $proc = Get-Process -Id $old -ErrorAction SilentlyContinue
                if ($proc -and -not $proc.HasExited) {
                    $isOurs = $false
                    try {
                        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$old" -ErrorAction Stop
                        if ($ci -and $ci.CommandLine -and $ci.CommandLine -match 'tasks-panel\.ps1') { $isOurs = $true }
                    } catch {
                        if (@('powershell','pwsh') -contains $proc.ProcessName) { $isOurs = $true }
                    }
                    if ($isOurs) {
                        try { [void]$proc.CloseMainWindow(); if (-not $proc.WaitForExit(1500)) { $proc.Kill() } }
                        catch { try { $proc.Kill() } catch { } }
                    }
                }
            }
        }
    } catch { }
    try { [System.IO.File]::WriteAllText($PidFile, [string]$PID) } catch { }
}

$form.Add_Shown({
    Enforce-SingleInstance              # close any prior instance; keep only this one
    try { [Dark]::DarkScroll($content.Handle) } catch { }
    if ($script:Files.Count -eq 0) { Add-Files }   # first-run file picker
    Update-Now -force
    Set-Rolled $script:Rolled          # apply saved roll state + button glyph
    Start-UpdateCheck                  # check on open
})
$form.Add_FormClosing({
    $script:PosX = $form.Location.X; $script:PosY = $form.Location.Y
    $script:PosW = $form.Width
    if (-not $script:Rolled) { $script:PosH = $form.Height }   # keep the expanded height
    Save-Config; $timer.Stop()
    # Remove our PID stamp only if it's still ours (a newer instance may own it now).
    try { if ((Test-Path $PidFile) -and ((([string](Get-Content $PidFile -Raw)).Trim()) -eq [string]$PID)) { Remove-Item $PidFile -Force } } catch { }
})

[void][System.Windows.Forms.Application]::Run($form)
