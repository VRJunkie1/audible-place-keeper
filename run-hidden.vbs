' Launches the Audible Place Keeper with no console window.
' Works out its own folder, so it runs from wherever you put it.
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\place-keeper.ps1""", 0, False
