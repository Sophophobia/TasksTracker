' Launch the Tasks Tracker panel with no console window.
' Runs tasks-panel.ps1 from this script's own folder, so the folder is portable.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
here  = fso.GetParentFolderName(WScript.ScriptFullName)
panel = fso.BuildPath(here, "tasks-panel.ps1")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File """ & panel & """", 0, False
