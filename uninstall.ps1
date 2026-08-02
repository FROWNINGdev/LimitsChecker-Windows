<#
    Removes the Startup shortcut, stops the tray app and deletes
    %LOCALAPPDATA%\LimitsChecker.

        powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>

$ErrorActionPreference = 'Continue'

$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'LimitsChecker.lnk'
if (Test-Path -LiteralPath $startup) {
    Remove-Item -LiteralPath $startup -Force
    Write-Host "removed $startup"
}

Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | ForEach-Object {
    try {
        $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
        if ($cmdline -and $cmdline -like '*LimitsChecker.ps1*') {
            Stop-Process -Id $_.Id -Force
            Write-Host "stopped pid $($_.Id)"
        }
    } catch { }
}

$target = Join-Path $env:LOCALAPPDATA 'LimitsChecker'
if (Test-Path -LiteralPath $target) {
    # Do not delete the folder out from under a copy of this script running from
    # inside it - schedule the removal instead.
    $self = $MyInvocation.MyCommand.Path
    if ($self -and $self.StartsWith($target, [StringComparison]::OrdinalIgnoreCase)) {
        Start-Process -FilePath 'cmd.exe' -WindowStyle Hidden -ArgumentList `
            '/c', 'timeout /t 2 /nobreak >nul & rmdir /s /q', ('"' + $target + '"')
        Write-Host "removing $target"
    } else {
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Host "removed $target"
    }
}
Write-Host "done"
