<#
  tasks-panel.ps1  --  Tasks Tracker floating panel

  A small, always-on-top, draggable + resizable, READ-ONLY panel that shows a
  live task list parsed from one or more Markdown files. It never writes /
  modifies the source files -- it only polls their mtime (~2s) and re-parses
  when any of them changes.

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
}

# ------------------------------------------------------------- paths --------
$ConfigPath = Join-Path $PSScriptRoot 'config.json'

# ------------------------------------------------------------- config -------
$script:Files     = @()      # list of absolute file paths to read
$script:PosX = $null; $script:PosY = $null
$script:PosW = 440; $script:PosH = 470
$script:Collapsed = @{ InProgress = $false; Pending = $false; Done = $true }

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
            if ($null -ne $c.collapsed) {
                foreach ($k in 'InProgress','Pending','Done') {
                    if ($null -ne $c.collapsed.$k) { $script:Collapsed[$k] = [bool]$c.collapsed.$k }
                }
            } elseif ($null -ne $c.doneCollapsed) { $script:Collapsed['Done'] = [bool]$c.doneCollapsed }
        }
    } catch { }
}

function Save-Config {
    try {
        $obj = [ordered]@{
            files     = @($script:Files)
            x = $script:PosX; y = $script:PosY; w = $script:PosW; h = $script:PosH
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

# Parse one file's text into task records. $defaultProject is the fallback
# project name (the file name); a `# Project: X` line overrides it.
function Parse-File($raw, $defaultProject) {
    $recs = @()
    if ([string]::IsNullOrEmpty($raw)) { return $recs }

    $project = $defaultProject
    # Pre-scan for a project override so it applies to the whole file.
    foreach ($line in ($raw -split "`n")) {
        if ($line -match $script:rxProj) { $project = $matches[1].Trim(); break }
    }

    $area = ''
    $section = 'Pending'
    foreach ($line in ($raw -split "`n")) {
        $line = $line.TrimEnd("`r")

        $m = $null
        if     ($line -match $script:rxTaskSep) { $m = @($matches[1], $matches[2], $matches[3]) }
        elseif ($line -match $script:rxTaskTxt) { $m = @($matches[1], $matches[2], $matches[3]) }
        elseif ($line -match $script:rxTaskId)  { $m = @($matches[1], $matches[2], '') }
        if ($m) {
            $id = $m[0] + $m[1]
            $r = Strip-StatusEmoji $m[2] $section
            $recs += [pscustomobject]@{
                id = $id; status = $r[0]; area = $area; project = $project; task = ([string]$r[1]).Trim()
            }
            continue
        }

        if ($line -match '^##\s') {
            if     ($line.Contains($G.inprog))  { $section = 'InProgress' }
            elseif ($line.Contains($G.pending)) { $section = 'Pending' }
            elseif ($line.Contains($G.done))    { $section = 'Done' }
            elseif ($line -match '(?i)\b(in[\s-]?progress|wip|doing|ongoing)\b')       { $section = 'InProgress' }
            elseif ($line -match '(?i)\b(pending|to[\s-]?do|backlog|planned|later)\b') { $section = 'Pending' }
            elseif ($line -match '(?i)\b(done|complete[d]?|finished|shipped)\b')        { $section = 'Done' }
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

function StatusColor($st) {
    switch ($st) { 'InProgress' { return $cInProg } 'Done' { return $cDone } default { return $cPending } }
}

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
$form.Width           = [Math]::Max($MinW, $script:PosW)
$form.Height          = [Math]::Max($MinH, $script:PosH)
$form.StartPosition   = 'Manual'

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($null -ne $script:PosX -and $null -ne $script:PosY) {
    $form.Location = New-Object System.Drawing.Point($script:PosX, $script:PosY)
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
$lblTime = New-Object System.Windows.Forms.Label
$lblTime.ForeColor = $cBarDim; $lblTime.Font = $fTime
$lblTime.AutoSize = $false; $lblTime.Dock = 'Right'; $lblTime.Width = 70; $lblTime.TextAlign = 'MiddleRight'
$bar.Controls.Add($lblTime)

$btnClose   = New-BarButton $G.close   30
$btnMenu    = New-BarButton $G.menu    28
$btnRefresh = New-BarButton $G.refresh 28
$bar.Controls.Add($btnRefresh); $bar.Controls.Add($btnMenu); $bar.Controls.Add($btnClose)
$tip.SetToolTip($btnRefresh, 'Refresh now'); $tip.SetToolTip($btnMenu, 'Menu'); $tip.SetToolTip($btnClose, 'Close panel')
$btnClose.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(248,113,113) })
$title.SendToBack()

# ---- scrollable content ----
$content = New-Object System.Windows.Forms.Panel
$content.Dock = 'Fill'; $content.BackColor = $cBg; $content.AutoScroll = $true
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

    $content.SuspendLayout()
    $row.Height = Set-TaskLabelState $tl $expand $tl.Width
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

    $order = @(
        @{ key='InProgress'; label='In progress'; color=$cInProg },
        @{ key='Pending';    label='Pending';     color=$cPending },
        @{ key='Done';       label='Done';        color=$cDone }
    )

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
            $expanded = [bool]$script:Expanded[$rowKey]
            $tag = if ($r.area) { $r.area } else { $r.project }

            $row = New-Object System.Windows.Forms.Panel
            $row.Dock = 'Top'; $row.BackColor = $cBg

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

            $row.Tag = $rowKey; $row.Cursor = 'Hand'; $row.Add_Click($script:onRowClick)
            foreach ($k in @($row.Controls)) { $k.Tag = $rowKey; $k.Cursor = 'Hand'; $k.Add_Click($script:onRowClick) }
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
        $lblTime.Text = ''; $script:LastMtime = $null; $script:LastSig = '__none__'
        return
    }

    $mt = Combined-Mtime
    if (-not $force -and $null -ne $script:LastMtime -and $mt -eq $script:LastMtime) { return }

    $all = @()
    foreach ($f in $script:Files) {
        if (-not (Test-Path $f)) { continue }
        $raw = Read-TasksFile $f
        if ($null -eq $raw) { return }    # locked mid-write: skip this round, retry
        $all += Parse-File $raw (Get-ProjectName $f)
    }

    $script:LastMtime = $mt
    $lblTime.Text = $G.refresh + ' ' + (Get-Date).ToString('HH:mm:ss')
    $tip.SetToolTip($title, ($script:Files -join "`n"))

    $sig = ($all | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.project,$_.id,$_.status,$_.area,$_.task }) -join "`n"
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

# ------------------------------------------------------------- buttons ------
$btnRefresh.Add_Click({ Update-Now -force })
$btnClose.Add_Click({ $form.Close() })

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
    $miExpand.Add_Click({ foreach ($k in 'InProgress','Pending','Done') { $script:Collapsed[$k] = $false }; Save-Config; Update-Now -force })
    [void]$menu.Items.Add($miExpand)
    $miCollapse = New-Object System.Windows.Forms.ToolStripMenuItem('Collapse all sections'); $miCollapse.ForeColor = $cText
    $miCollapse.Add_Click({ foreach ($k in 'InProgress','Pending','Done') { $script:Collapsed[$k] = $true }; Save-Config; Update-Now -force })
    [void]$menu.Items.Add($miCollapse)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miQuit = New-Object System.Windows.Forms.ToolStripMenuItem('Close panel'); $miQuit.ForeColor = $cText
    $miQuit.Add_Click({ $form.Close() })
    [void]$menu.Items.Add($miQuit)

    $menu.Show($btnMenu, (New-Object System.Drawing.Point(0, $TitleH)))
})

# ------------------------------------------------------------- dragging -----
$script:dragging = $false
$script:dragOff  = New-Object System.Drawing.Point(0,0)
$startDrag = { param($s,$e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:dragging = $true; $script:dragOff = New-Object System.Drawing.Point($e.X, $e.Y) } }
$doDrag = { param($s,$e) if ($script:dragging) { $p = [System.Windows.Forms.Cursor]::Position; $form.Location = New-Object System.Drawing.Point(($p.X - $script:dragOff.X), ($p.Y - $script:dragOff.Y)) } }
$endDrag = { param($s,$e) if ($script:dragging) { $script:dragging = $false; $script:PosX = $form.Location.X; $script:PosY = $form.Location.Y; Save-Config } }
foreach ($ctl in @($bar, $title)) { $ctl.Add_MouseDown($startDrag); $ctl.Add_MouseMove($doDrag); $ctl.Add_MouseUp($endDrag) }

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

# ------------------------------------------------------------- timer --------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Now })
$timer.Start()

$form.Add_Shown({
    try { [Dark]::DarkScroll($content.Handle) } catch { }
    if ($script:Files.Count -eq 0) { Add-Files }   # first-run file picker
    Update-Now -force
})
$form.Add_FormClosing({
    $script:PosX = $form.Location.X; $script:PosY = $form.Location.Y
    $script:PosW = $form.Width; $script:PosH = $form.Height
    Save-Config; $timer.Stop()
})

[void][System.Windows.Forms.Application]::Run($form)
