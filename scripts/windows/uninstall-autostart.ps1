# Nav Coaching - remove automatic start and stop the background server.
# Your library, clients, programs and backups in the data folder are NOT touched.
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$TaskName = "NavCoaching"
$PythonW = Join-Path $Root ".venv\Scripts\pythonw.exe"

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
}
$lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Nav Coaching.lnk"
if (Test-Path $lnk) { Remove-Item $lnk; Write-Host "Removed Startup shortcut." }
Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $PythonW } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Stopped the running server." }
Write-Host "Done. Your data folder was not changed."
