' Record-only mode. Watches and writes down where you are, and NEVER touches
' the player - no clicks at all, so it cannot steal focus or make noise.
' Use this while you are working at the machine.
' The normal launcher (run-hidden.vbs) also restores your place, but only once
' you have been away from the keyboard for a few minutes.
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\place-keeper.ps1"" -NoRestore", 0, False
