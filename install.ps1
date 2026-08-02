<#
    Installs LimitsChecker into %LOCALAPPDATA%\LimitsChecker, adds a Startup
    shortcut, and launches the tray app. No admin rights needed.

        powershell -ExecutionPolicy Bypass -File install.ps1
#>

param(
    [switch]$NoAutostart,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

$source = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $env:LOCALAPPDATA 'LimitsChecker'
$files  = @('LimitsChecker.ps1', 'LimitsChecker.vbs', 'uninstall.ps1', 'README.md')

foreach ($f in @('LimitsChecker.ps1', 'LimitsChecker.vbs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $f) -PathType Leaf)) {
        throw "missing $f next to install.ps1"
    }
}

# A running instance holds no lock on the scripts, but stop it so the new code
# is what ends up in the tray.
Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | ForEach-Object {
    try {
        $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
        if ($cmdline -and $cmdline -like '*LimitsChecker.ps1*') {
            Write-Host "stopping running instance (pid $($_.Id))"
            Stop-Process -Id $_.Id -Force
        }
    } catch { }
}

if (-not (Test-Path -LiteralPath $target)) {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
}
foreach ($f in $files) {
    $src = Join-Path $source $f
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $target $f) -Force
    }
}
Write-Host "installed to $target"

$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'LimitsChecker.lnk'
if ($NoAutostart) {
    if (Test-Path -LiteralPath $startup) { Remove-Item -LiteralPath $startup -Force }
    Write-Host "autostart: off"
} else {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($startup)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $target 'LimitsChecker.vbs') + '"'
    $lnk.WorkingDirectory = $target
    $lnk.Description = 'LimitsChecker - Claude Code usage limits in the tray'
    $lnk.Save()
    Write-Host "autostart: $startup"
}

if (-not $NoLaunch) {
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') `
                  -ArgumentList ('"' + (Join-Path $target 'LimitsChecker.vbs') + '"')
    Write-Host "started - look for the colored percentage icon in the tray (^ to expand)"
}
