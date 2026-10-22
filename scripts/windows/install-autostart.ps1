# Nav Coaching - start automatically in the background when you sign in to Windows.
# Run via install-autostart.bat (double-click). Safe to run again after updating the code.
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$TaskName = "NavCoaching"
$Venv = Join-Path $Root ".venv"
$PythonW = Join-Path $Venv "Scripts\pythonw.exe"
$Python = Join-Path $Venv "Scripts\python.exe"

function Find-Python {
    foreach ($cmd in @(@("py", "-3"), @("python"))) {
        try {
            $exe = $cmd[0]
            $pyArgs = @($cmd | Select-Object -Skip 1)
            $v = & $exe @pyArgs -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $v) {
                $parts = $v.Trim().Split('.')
                if ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 10) { return , $cmd }
            }
        } catch { }
    }
    throw "Python 3.10+ was not found. Install it from python.org (tick 'Add python.exe to PATH'), then run this again."
}

function Stop-NavCoaching {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $PythonW } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host "Nav Coaching folder: $Root"
if (-not (Test-Path $PythonW)) {
    $py = Find-Python
    $exe = $py[0]
    $pyArgs = @($py | Select-Object -Skip 1)
    Write-Host "Creating virtual environment (.venv)..."
    & $exe @pyArgs -m venv $Venv
    if ($LASTEXITCODE -ne 0) { throw "Could not create the virtual environment." }
}
Write-Host "Installing / updating dependencies..."
& $Python -m pip install -q --disable-pip-version-check -r (Join-Path $Root "requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "Installing dependencies failed (see messages above)." }

Stop-NavCoaching

$user = "$env:USERDOMAIN\$env:USERNAME"
$mode = "task"
try {
    $action = New-ScheduledTaskAction -Execute $PythonW -Argument "-m navcoach.main" -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description "Nav Coaching local server" -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
} catch {
    # Fallback that needs no administrator rights: a hidden shortcut in the Startup folder.
    Write-Host "Task Scheduler registration was not allowed; using the Startup folder instead."
    $mode = "startup"
    $lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Nav Coaching.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = $PythonW
    $s.Arguments = "-m navcoach.main"
    $s.WorkingDirectory = $Root
    $s.WindowStyle = 7
    $s.Save()
    Start-Process -FilePath $PythonW -ArgumentList "-m navcoach.main" -WorkingDirectory $Root -WindowStyle Hidden
}

$port = 8000
$envFile = Join-Path $Root ".env"
if (Test-Path $envFile) {
    $m = Select-String -Path $envFile -Pattern '^\s*NAV_PORT\s*=\s*(\d+)' | Select-Object -First 1
    if ($m) { $port = [int]$m.Matches[0].Groups[1].Value }
}
$ok = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 2
        if ($r.ok) { $ok = $true; break }
    } catch { }
}
Write-Host ""
if ($ok) {
    Write-Host "OK - Nav Coaching is running at http://127.0.0.1:$port (auto-start: $mode)."
    Write-Host "It will start by itself every time you sign in to Windows."
    Write-Host "For the iPad, run once:  tailscale serve --bg $port"
} else {
    Write-Host "Auto-start is registered, but the app did not answer yet."
    Write-Host "Check the log: $(Join-Path $Root 'data\navcoach.log')"
    exit 1
}
