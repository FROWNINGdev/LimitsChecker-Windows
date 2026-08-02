<#
    LimitsChecker for Windows - a system-tray app for Claude Code usage limits.

    The Windows counterpart of the GNOME indicator / macOS menu-bar app. Same
    data layer (Anthropic OAuth usage API), rendered with WinForms NotifyIcon
    instead of AppIndicator / rumps.

        GET https://api.anthropic.com/api/oauth/usage
        Authorization: Bearer <accessToken>
        anthropic-beta: oauth-2025-04-20

    Token source on Windows: Claude Code stores credentials in
    %USERPROFILE%\.claude\.credentials.json. If that file is missing, the
    Windows Credential Manager is tried (generic credential, target name
    configurable via LIMITSCHECKER_CREDENTIAL_TARGET).

    The tray icon can carry no text on Windows, so the panel line
    ("Session 5% - Week 42% - Fable 59%") goes to the tooltip and the icon
    itself is drawn at runtime: the highest percentage, colored by threshold.

    Run:
        wscript.exe LimitsChecker.vbs           (hidden, no console)
        powershell -ExecutionPolicy Bypass -File LimitsChecker.ps1

    NOTE: this file is deliberately pure ASCII so it loads identically whether
    or not it carries a BOM. Bar glyphs are built from [char] codes below.
#>

param(
    # One synchronous poll printed to the console, then exit. No tray, no loop.
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Only one tray icon per user session - a second launch just exits.
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\LimitsCheckerWindowsTray', [ref]$created)
if (-not $created) { return }

# ---------------------------------------------------------------- native bits
if (-not ('LcNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LcNative
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr handle);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr cred);

    // Reads a CRED_TYPE_GENERIC secret. Returns null when absent.
    public static string ReadGenericCredential(string target)
    {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) { return null; }
        try
        {
            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            if (c.CredentialBlobSize == 0) { return null; }
            byte[] buf = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, buf, 0, (int)c.CredentialBlobSize);
            // The blob has no declared encoding; UTF-16 shows as NUL in every
            // second byte, anything else is read as UTF-8.
            bool unicode = buf.Length >= 2 && buf.Length % 2 == 0;
            if (unicode)
            {
                for (int i = 1; i < buf.Length; i += 2)
                {
                    if (buf[i] != 0) { unicode = false; break; }
                }
            }
            return unicode
                ? System.Text.Encoding.Unicode.GetString(buf)
                : System.Text.Encoding.UTF8.GetString(buf);
        }
        finally { CredFree(p); }
    }
}

// WinForms menus ignore the Windows 11 dark theme, so supply the colors.
public class LcDarkColors : System.Windows.Forms.ProfessionalColorTable
{
    private static System.Drawing.Color C(int r, int g, int b) { return System.Drawing.Color.FromArgb(r, g, b); }
    public override System.Drawing.Color ToolStripDropDownBackground { get { return C(43, 43, 43); } }
    public override System.Drawing.Color MenuBorder { get { return C(80, 80, 80); } }
    public override System.Drawing.Color MenuItemBorder { get { return C(100, 100, 100); } }
    public override System.Drawing.Color MenuItemSelected { get { return C(70, 70, 70); } }
    public override System.Drawing.Color MenuItemSelectedGradientBegin { get { return C(70, 70, 70); } }
    public override System.Drawing.Color MenuItemSelectedGradientEnd { get { return C(70, 70, 70); } }
    public override System.Drawing.Color MenuItemPressedGradientBegin { get { return C(60, 60, 60); } }
    public override System.Drawing.Color MenuItemPressedGradientEnd { get { return C(60, 60, 60); } }
    public override System.Drawing.Color ImageMarginGradientBegin { get { return C(43, 43, 43); } }
    public override System.Drawing.Color ImageMarginGradientMiddle { get { return C(43, 43, 43); } }
    public override System.Drawing.Color ImageMarginGradientEnd { get { return C(43, 43, 43); } }
    public override System.Drawing.Color SeparatorDark { get { return C(80, 80, 80); } }
    public override System.Drawing.Color SeparatorLight { get { return C(80, 80, 80); } }
    public override System.Drawing.Color CheckBackground { get { return C(70, 70, 70); } }
    public override System.Drawing.Color CheckSelectedBackground { get { return C(90, 90, 90); } }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing
}

# --------------------------------------------------------------------- config
# Every option is read from LIMITSCHECKER_* first, then CLAUDEBAR_* (the name
# used by the Linux indicator), so both spellings work.
function Get-EnvRaw([string]$suffix) {
    foreach ($prefix in @('LIMITSCHECKER_', 'CLAUDEBAR_')) {
        $v = [Environment]::GetEnvironmentVariable($prefix + $suffix)
        if (-not [string]::IsNullOrEmpty($v)) { return $v }
    }
    return $null
}

function Get-EnvStr([string]$suffix, [string]$default) {
    $v = Get-EnvRaw $suffix
    if ($null -eq $v) { return $default }
    return $v
}

# Bad values fall back to the default and clamp, so a stray env var can never
# stop the app from starting under autostart.
function Get-EnvInt([string]$suffix, [int]$default, $lo, $hi) {
    $value = $default
    $raw = Get-EnvRaw $suffix
    if ($null -ne $raw) {
        $parsed = 0
        if ([int]::TryParse($raw.Trim(), [ref]$parsed)) { $value = $parsed }
    }
    if ($null -ne $lo -and $value -lt $lo) { $value = $lo }
    if ($null -ne $hi -and $value -gt $hi) { $value = $hi }
    return $value
}

function Get-EnvBool([string]$suffix, [bool]$default) {
    $raw = Get-EnvRaw $suffix
    if ($null -eq $raw) { return $default }
    return ($raw.Trim().ToLowerInvariant() -notin @('0', 'false', 'no', 'off'))
}

$APP_TITLE   = Get-EnvStr 'TITLE' 'LimitsChecker'
$CREDENTIALS = Get-EnvStr 'CREDENTIALS' (Join-Path $env:USERPROFILE '.claude\.credentials.json')
$CRED_TARGET = Get-EnvStr 'CREDENTIAL_TARGET' 'Claude Code-credentials'
$ENDPOINT    = Get-EnvStr 'ENDPOINT' 'https://api.anthropic.com/api/oauth/usage'
$BETA_HEADER = Get-EnvStr 'BETA' 'oauth-2025-04-20'
$REFRESH_SECONDS = Get-EnvInt 'REFRESH_SECONDS' 60 5 $null
# After a failed poll, retry this soon instead of waiting the full refresh cycle.
$RETRY_SECONDS   = Get-EnvInt 'RETRY_SECONDS' 30 5 $null
# Attempts per poll to ride out a transient blip (rate-limit / network hiccup).
$FETCH_ATTEMPTS  = Get-EnvInt 'FETCH_ATTEMPTS' 3 1 10
$TIMEOUT         = Get-EnvInt 'TIMEOUT' 30 1 $null
$WARN_PERCENT    = Get-EnvInt 'WARN_PERCENT' 80 0 100
$BAR_WIDTH       = Get-EnvInt 'BAR_WIDTH' 10 0 100
$FILL_CHAR       = Get-EnvStr 'FILL_CHAR'  ([string][char]0x2588)   # full block
$TRACK_CHAR      = Get-EnvStr 'TRACK_CHAR' ([string][char]0x2592)   # medium shade
$NAME_SESSION    = Get-EnvStr 'NAME_SESSION' 'Session'
$NAME_WEEK       = Get-EnvStr 'NAME_WEEK' 'Week'
$SHOW_SCOPED     = Get-EnvBool 'SHOW_SCOPED' $true
# weekly_scoped rows the API marks inactive are hidden by default, as upstream.
$SCOPED_INACTIVE = Get-EnvBool 'SCOPED_INACTIVE' $false
$NOTIFY          = Get-EnvBool 'NOTIFY' $true
$ICON_PATH       = Get-EnvStr 'ICON' ''
$MENU_FONT       = Get-EnvStr 'MENU_FONT' 'Segoe UI'
$ROW_SLOTS       = 12   # reusable menu rows for usage windows (generous)

$SEP  = ' ' + [char]0x00B7 + ' '   # middle dot between panel cells
$WARN = [char]0x26A0 + ' '         # warning sign badge

# --------------------------------------------------------------- token source
function Read-TokenFromJson([string]$blob, [string]$where) {
    try { $data = $blob | ConvertFrom-Json } catch { throw "${where}: not valid JSON" }
    $oauth = $data.PSObject.Properties['claudeAiOauth']
    if (-not $oauth) { throw "${where}: no claudeAiOauth section" }
    $token = $oauth.Value.PSObject.Properties['accessToken']
    if (-not $token -or [string]::IsNullOrEmpty([string]$token.Value)) { throw "${where}: no accessToken" }
    return [string]$token.Value
}

# Re-read on every poll, so a token Claude Code refreshed in the background is
# picked up without a restart.
function Read-Token {
    if (Test-Path -LiteralPath $CREDENTIALS -PathType Leaf) {
        try { $blob = Get-Content -LiteralPath $CREDENTIALS -Raw -Encoding UTF8 }
        catch { throw "cannot read ${CREDENTIALS}: $($_.Exception.Message)" }
        return Read-TokenFromJson $blob $CREDENTIALS
    }
    $secret = $null
    try { $secret = [LcNative]::ReadGenericCredential($CRED_TARGET) } catch { $secret = $null }
    if (-not [string]::IsNullOrEmpty($secret)) {
        return Read-TokenFromJson $secret ('credential "' + $CRED_TARGET + '"')
    }
    throw ("no token - $CREDENTIALS missing and Credential Manager entry " +
           "`"$CRED_TARGET`" not found. Log in with Claude Code, or set " +
           "LIMITSCHECKER_CREDENTIALS.")
}

# ------------------------------------------------------------- fetch (worker)
# Runs in a background runspace so a slow endpoint never freezes the tray.
# Returns @{ Ok; Raw; Error; Transient }.
$Worker = {
    param($cfg)

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    # API errors come back as {"type":"error","error":{"type":..,"message":..}}.
    # The menu note is one short line, so pull just the human message out and
    # never let a raw JSON blob (or an HTML gateway page) reach the UI.
    function Get-ErrorDetail([string]$body, [string]$fallback) {
        $text = ''
        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $trimmed = $body.Trim()
            if ($trimmed.StartsWith('{')) {
                try {
                    $obj = $trimmed | ConvertFrom-Json
                    $msg = $null
                    $err = $obj.PSObject.Properties['error']
                    if ($err -and $err.Value) {
                        $inner = $err.Value.PSObject.Properties['message']
                        if ($inner) { $msg = [string]$inner.Value }
                    }
                    if ([string]::IsNullOrWhiteSpace($msg)) {
                        $top = $obj.PSObject.Properties['message']
                        if ($top) { $msg = [string]$top.Value }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($msg)) { $text = $msg }
                } catch { }
            } elseif (-not $trimmed.StartsWith('<')) {
                # Plain-text body is usable as-is; an HTML gateway page is noise.
                $text = $trimmed
            }
        }
        if ([string]::IsNullOrWhiteSpace($text)) { $text = $fallback }
        if ($null -eq $text) { $text = '' }
        $text = ($text -replace '\s+', ' ').Trim()
        if ($text.Length -gt 90) { $text = $text.Substring(0, 89).TrimEnd() + [string][char]0x2026 }
        return $text
    }

    function Invoke-Once($cfg) {
        $req = [System.Net.HttpWebRequest]::Create($cfg.Endpoint)
        $req.Method           = 'GET'
        $req.Timeout          = $cfg.TimeoutSec * 1000
        $req.ReadWriteTimeout = $cfg.TimeoutSec * 1000
        $req.UserAgent        = 'limitschecker-windows'
        $req.Accept           = 'application/json'
        $req.Headers.Add('Authorization', 'Bearer ' + $cfg.Token)
        $req.Headers.Add('anthropic-beta', $cfg.Beta)
        try {
            $resp = $req.GetResponse()
            try {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $raw = $reader.ReadToEnd()
                $reader.Close()
            } finally { $resp.Close() }
            return @{ Ok = $true; Raw = $raw; Error = $null; Transient = $false; RetryAfter = $null }
        } catch [System.Net.WebException] {
            $we = $_.Exception
            $resp = $we.Response
            if ($null -eq $resp) {
                # No response at all: DNS, offline, TLS, timeout - all transient.
                return @{ Ok = $false; Error = "network error: $($we.Message)"; Transient = $true; RetryAfter = $null }
            }
            $code = 0
            try { $code = [int]$resp.StatusCode } catch { $code = 0 }
            $body = ''
            try {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reader.Close()
            } catch { }
            if ($body.Length -gt 2000) { $body = $body.Substring(0, 2000) }
            $detail = Get-ErrorDetail $body $we.Message
            $retryAfter = $null
            try {
                $hdr = $resp.Headers['Retry-After']
                if ($hdr) {
                    $parsed = 0.0
                    if ([double]::TryParse($hdr, [ref]$parsed)) { $retryAfter = $parsed }
                }
            } catch { }
            try { $resp.Close() } catch { }

            if ($code -eq 401) {
                # Auth failures are not transient - the token is dead until
                # Claude Code (or a re-login) refreshes the credentials.
                return @{ Ok = $false; Error = '401 unauthorized - token invalid/expired, re-login to Claude'; Transient = $false; RetryAfter = $null }
            }
            if ($code -eq 429) {
                # The API's own wording is long and repeats on every retry; the
                # menu only needs the status - the UI appends when it will ask
                # again. Without a Retry-After header, wait a full refresh cycle
                # rather than the shorter default: asking sooner just fails.
                if ($null -eq $retryAfter -or $retryAfter -le 0) { $retryAfter = 60.0 }
                return @{ Ok = $false; Error = 'rate-limited (429)'; Transient = $true; RetryAfter = $retryAfter; RateLimited = $true }
            }
            if ($code -ge 500) {
                return @{ Ok = $false; Error = "server error (HTTP $code)"; Transient = $true; RetryAfter = $retryAfter }
            }
            return @{ Ok = $false; Error = "HTTP ${code}: $detail"; Transient = $false; RetryAfter = $null }
        } catch {
            return @{ Ok = $false; Error = "network error: $($_.Exception.Message)"; Transient = $true; RetryAfter = $null }
        }
    }

    $result = $null
    for ($attempt = 0; $attempt -lt $cfg.Attempts; $attempt++) {
        $result = Invoke-Once $cfg
        if ($result.Ok -or -not $result.Transient) { break }
        # A 429 never clears within a few seconds, and retrying inside the poll
        # only deepens the throttle. Hand it straight to the retry timer, which
        # waits out Retry-After.
        if ($result.RateLimited) { break }
        if ($attempt + 1 -lt $cfg.Attempts) {
            # Short in-fetch backoff only; longer waits belong to the retry timer.
            $delay = if ($null -ne $result.RetryAfter) { $result.RetryAfter } else { 1 + $attempt * 2 }
            if ($delay -lt 0) { $delay = 0 }
            if ($delay -gt 5) { $delay = 5 }
            Start-Sleep -Milliseconds ([int]($delay * 1000))
        }
    }
    $result
}

# ------------------------------------------------------------------ view model
function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-Pct($value) {
    if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
        $v = [int][math]::Round([double]$value, [MidpointRounding]::AwayFromZero)
        if ($v -lt 0) { $v = 0 }
        if ($v -gt 999) { $v = 999 }
        return $v
    }
    return $null
}

function ConvertTo-Dt($raw) {
    if ($null -eq $raw -or -not ($raw -is [string]) -or $raw -eq '') { return $null }
    $dto = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParse(
        $raw, [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$dto)
    if ($ok) { return $dto }
    return $null
}

function Format-ResetAbsolute($raw) {
    $dt = ConvertTo-Dt $raw
    if ($null -eq $dt) { return $null }
    return $dt.ToLocalTime().ToString('MMM dd HH:mm', [cultureinfo]::InvariantCulture)
}

function Format-ResetCountdown($raw) {
    $dt = ConvertTo-Dt $raw
    if ($null -eq $dt) { return $null }
    $secs = ($dt - [DateTimeOffset]::Now).TotalSeconds
    if ($secs -le 0) { return 'now' }
    $minutes = [int][math]::Floor($secs / 60)
    $hours = [int][math]::Floor($minutes / 60); $minutes = $minutes % 60
    $days = [int][math]::Floor($hours / 24);    $hours = $hours % 24
    if ($days -gt 0)  { return "${days}d ${hours}h" }
    if ($hours -gt 0) { return "${hours}h ${minutes}m" }
    return "${minutes}m"
}

function Format-Bar($pct) {
    $p = 0
    if ($null -ne $pct) { $p = [int]$pct }
    if ($p -lt 0) { $p = 0 }
    if ($p -gt 100) { $p = 100 }
    $filled = [int][math]::Round($p / 100.0 * $BAR_WIDTH, [MidpointRounding]::AwayFromZero)
    return ($FILL_CHAR * $filled) + ($TRACK_CHAR * ($BAR_WIDTH - $filled))
}

# limits[] is the primary source; five_hour / seven_day are the fallback for
# older/thinner responses.
function Build-View($payload) {
    $rows = New-Object System.Collections.ArrayList
    $scopedNames = New-Object System.Collections.Generic.HashSet[string]
    $warn = $false
    $spend = $null

    $sessionPct = $null;  $sessionReset = $null
    $weeklyPct  = $null;  $weeklyReset  = $null
    $scoped = New-Object System.Collections.ArrayList

    $limits = Get-Prop $payload 'limits'
    if ($limits -is [System.Array]) {
        foreach ($lim in $limits) {
            if ($null -eq $lim) { continue }
            $kind  = [string](Get-Prop $lim 'kind')
            $pct   = ConvertTo-Pct (Get-Prop $lim 'percent')
            $reset = Get-Prop $lim 'resets_at'
            $sev   = [string](Get-Prop $lim 'severity')
            if ($sev -ne '' -and $sev -ne 'normal') { $warn = $true }
            if ($kind -eq 'session') {
                $sessionPct = $pct; $sessionReset = $reset
            } elseif ($kind -eq 'weekly_all') {
                $weeklyPct = $pct; $weeklyReset = $reset
            } elseif ($kind -eq 'weekly_scoped' -and $null -ne $pct) {
                $active = Get-Prop $lim 'is_active'
                if ($null -eq $active) { $active = $true }
                if ($active -or $SCOPED_INACTIVE) {
                    $scope = Get-Prop $lim 'scope'
                    $model = Get-Prop $scope 'model'
                    $label = [string](Get-Prop $model 'display_name')
                    if ([string]::IsNullOrEmpty($label)) { $label = [string](Get-Prop $scope 'surface') }
                    if ([string]::IsNullOrEmpty($label)) { $label = 'model' }
                    [void]$scoped.Add(@{ Name = $label; Pct = $pct; Reset = $reset })
                }
            }
        }
    }

    if ($null -eq $sessionPct) {
        $w = Get-Prop $payload 'five_hour'
        if ($null -ne $w) { $sessionPct = ConvertTo-Pct (Get-Prop $w 'utilization'); $sessionReset = Get-Prop $w 'resets_at' }
    }
    if ($null -eq $weeklyPct) {
        $w = Get-Prop $payload 'seven_day'
        if ($null -ne $w) { $weeklyPct = ConvertTo-Pct (Get-Prop $w 'utilization'); $weeklyReset = Get-Prop $w 'resets_at' }
    }

    [void]$rows.Add([pscustomobject]@{ Name = $NAME_SESSION; Pct = $sessionPct; Reset = $sessionReset })
    [void]$rows.Add([pscustomobject]@{ Name = $NAME_WEEK;    Pct = $weeklyPct;  Reset = $weeklyReset })
    foreach ($s in $scoped) {
        [void]$rows.Add([pscustomobject]@{ Name = $s.Name; Pct = $s.Pct; Reset = $s.Reset })
        [void]$scopedNames.Add([string]$s.Name)
    }

    $peak = 0
    foreach ($r in $rows) {
        if ($null -ne $r.Pct) {
            if ($r.Pct -ge $WARN_PERCENT) { $warn = $true }
            if ($r.Pct -gt $peak) { $peak = [int]$r.Pct }
        }
    }

    $extra = Get-Prop $payload 'extra_usage'
    if ($null -ne $extra -and (Get-Prop $extra 'is_enabled')) {
        $u = ConvertTo-Pct (Get-Prop $extra 'utilization')
        if ($null -ne $u) { $spend = "extra usage $u%" }
    }

    return [pscustomobject]@{
        Rows = @($rows); ScopedNames = $scopedNames; Warn = $warn; Spend = $spend; Peak = $peak
    }
}

function Format-PanelLabel($view) {
    $cells = @()
    foreach ($r in $view.Rows) {
        if (-not $SHOW_SCOPED -and $view.ScopedNames.Contains([string]$r.Name)) { continue }
        $val = if ($null -eq $r.Pct) { '--' } else { "$($r.Pct)%" }
        $cells += "$($r.Name) $val"
    }
    $text = if ($cells.Count -gt 0) { $cells -join $SEP } else { 'no data' }
    if ($view.Warn) { return $WARN + $text }
    return $text
}

# Bar-first rows, name column padded so the reset column lines up. The menu font
# is monospaced, so padding by character count is exact.
function Format-MenuRows($view) {
    $lines = @()
    $width = 0
    foreach ($r in $view.Rows) {
        if ($r.Name.Length -gt $width) { $width = $r.Name.Length }
    }
    foreach ($r in $view.Rows) {
        $name = ([string]$r.Name).PadRight($width)
        if ($null -eq $r.Pct) {
            $lines += ($TRACK_CHAR * $BAR_WIDTH) + '    --  ' + $name
            continue
        }
        $cd = Format-ResetCountdown $r.Reset
        $tail = if ($cd) { '   ' + [char]0x00B7 + '  resets in ' + $cd } else { '' }
        $lines += (Format-Bar $r.Pct) + '  ' + ("$($r.Pct)%".PadLeft(4)) + '  ' + $name + $tail
    }
    if ($view.Spend) { $lines += $view.Spend }
    return $lines
}

function Format-DetailsText($view) {
    $lines = @()
    foreach ($r in $view.Rows) {
        $val = if ($null -eq $r.Pct) { '--' } else { "$($r.Pct)%" }
        $at = Format-ResetAbsolute $r.Reset
        $line = "$($r.Name): $val"
        if ($at) { $line += "  (resets $at)" }
        $lines += $line
    }
    if ($view.Spend) { $lines += $view.Spend }
    return ($lines -join "`r`n")
}

# -------------------------------------------------------------------- selftest
if ($SelfTest) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    Write-Host "endpoint    : $ENDPOINT"
    Write-Host "credentials : $CREDENTIALS"
    $token = Read-Token
    Write-Host "token       : ok ($($token.Length) chars)"
    $cfg = @{ Endpoint = $ENDPOINT; Beta = $BETA_HEADER; Token = $token; TimeoutSec = $TIMEOUT; Attempts = $FETCH_ATTEMPTS }
    $res = & $Worker $cfg
    if (-not $res.Ok) {
        Write-Host "FETCH FAILED: $($res.Error) (transient=$($res.Transient))"
        exit 1
    }
    $view = Build-View ($res.Raw | ConvertFrom-Json)
    Write-Host ''
    Write-Host "tooltip     : $(Format-PanelLabel $view)"
    Write-Host ''
    Format-MenuRows $view | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host (Format-DetailsText $view)
    exit 0
}

# ------------------------------------------------------------------- palette
# One scale for the tray icon and the menu bars: green below WARN*0.6, amber up
# to the warn threshold, red at or above it.
$COLOR_OK   = [System.Drawing.Color]::FromArgb(255,  62, 173, 106)
$COLOR_MID  = [System.Drawing.Color]::FromArgb(255, 226, 160,  38)
$COLOR_HOT  = [System.Drawing.Color]::FromArgb(255, 226,  76,  76)
$COLOR_DEAD = [System.Drawing.Color]::FromArgb(255, 130, 130, 138)

function Get-LevelColor([int]$pct) {
    if ($pct -ge $WARN_PERCENT) { return $COLOR_HOT }
    if ($pct -ge [int]($WARN_PERCENT * 0.6)) { return $COLOR_MID }
    return $COLOR_OK
}

# ---------------------------------------------------------------- tray icon
$script:IconHandle = [IntPtr]::Zero

function New-TrayIcon([int]$pct, [bool]$warn, [bool]$isError) {
    if ($ICON_PATH -and (Test-Path -LiteralPath $ICON_PATH -PathType Leaf)) {
        try { return New-Object System.Drawing.Icon($ICON_PATH) } catch { }
    }
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)

        if ($isError) {
            $back = $COLOR_DEAD
            $text = '?'
        } else {
            $back = if ($warn) { $COLOR_HOT } else { Get-LevelColor $pct }
            $text = if ($pct -ge 100) { '99+' } else { [string]$pct }
        }

        $brush = New-Object System.Drawing.SolidBrush($back)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = 7
        $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
        $path.AddArc($size - $r * 2 - 1, 0, $r * 2, $r * 2, 270, 90)
        $path.AddArc($size - $r * 2 - 1, $size - $r * 2 - 1, $r * 2, $r * 2, 0, 90)
        $path.AddArc(0, $size - $r * 2 - 1, $r * 2, $r * 2, 90, 90)
        $path.CloseFigure()
        $g.FillPath($brush, $path)

        $emSize = switch ($text.Length) { 1 { 20 } 2 { 17 } default { 13 } }
        $font = New-Object System.Drawing.Font('Segoe UI', $emSize,
            [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $rect = New-Object System.Drawing.RectangleF(0, -1, $size, $size)
        $g.DrawString($text, $font, $white, $rect, $fmt)

        $brush.Dispose(); $white.Dispose(); $font.Dispose(); $fmt.Dispose(); $path.Dispose()
    } finally { $g.Dispose() }

    $hicon = $bmp.GetHicon()
    $bmp.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    # The clone owns managed memory only; the raw HICON is freed in Set-TrayIcon.
    $clone = $icon.Clone()
    $icon.Dispose()
    [void][LcNative]::DestroyIcon($hicon)
    return $clone
}

function Set-TrayIcon($notify, [int]$pct, [bool]$warn, [bool]$isError) {
    $old = $notify.Icon
    $notify.Icon = New-TrayIcon $pct $warn $isError
    if ($null -ne $old) { try { $old.Dispose() } catch { } }
}

# -------------------------------------------------------------------- autostart
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'LimitsChecker.lnk'

function Test-Autostart { return (Test-Path -LiteralPath $StartupLink -PathType Leaf) }

function Set-Autostart([bool]$enabled) {
    if (-not $enabled) {
        if (Test-Autostart) { Remove-Item -LiteralPath $StartupLink -Force }
        return
    }
    $dir = Split-Path -Parent $PSCommandPath
    $vbs = Join-Path $dir 'LimitsChecker.vbs'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($StartupLink)
    if (Test-Path -LiteralPath $vbs -PathType Leaf) {
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $lnk.Arguments = '"' + $vbs + '"'
    } else {
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
    }
    $lnk.WorkingDirectory = $dir
    $lnk.Description = "$APP_TITLE - Claude Code usage limits in the tray"
    $lnk.Save()
}

# ------------------------------------------------------------------------- UI
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
try {
    $menu.Font = New-Object System.Drawing.Font($MENU_FONT, 9.0)
} catch {
    $menu.Font = New-Object System.Drawing.Font('Consolas', 9.0)
}
$menu.ShowImageMargin = $false

# LIMITSCHECKER_THEME: auto (follow Windows) | dark | light
$theme = (Get-EnvStr 'THEME' 'auto').ToLowerInvariant()
if ($theme -eq 'auto') {
    $theme = 'light'
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $v = (Get-ItemProperty -Path $key -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ([int]$v -eq 0) { $theme = 'dark' }
    } catch { }
}
if ($theme -eq 'dark') {
    $menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object LcDarkColors))
    $menu.BackColor = [System.Drawing.Color]::FromArgb(43, 43, 43)
    $menu.ForeColor = [System.Drawing.Color]::FromArgb(238, 238, 238)
}

# Menu colors. Upstream draws bars from block glyphs because DBusMenu carries
# text only; a WinForms menu can be owner-drawn, so the bars are real colored
# rectangles here and the text columns are painted separately.
if ($theme -eq 'dark') {
    $CLR_TEXT  = [System.Drawing.Color]::FromArgb(238, 238, 238)
    $CLR_MUTED = [System.Drawing.Color]::FromArgb(150, 150, 155)
    $CLR_TRACK = [System.Drawing.Color]::FromArgb(72, 72, 76)
} else {
    $CLR_TEXT  = [System.Drawing.Color]::FromArgb(28, 28, 28)
    $CLR_MUTED = [System.Drawing.Color]::FromArgb(110, 110, 115)
    $CLR_TRACK = [System.Drawing.Color]::FromArgb(214, 214, 218)
}

$BAR_PX     = Get-EnvInt 'BAR_PX' 92 20 400   # bar length in the menu, pixels
$BAR_THICK  = 10
$PCT_PX     = 36
$PAD_X      = 8
$GAP        = 10
$script:NameColPx = 60   # widened to fit the longest window name on each update

$FONT_ROW  = $menu.Font
$FONT_PCT  = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($w -le 0) { return $path }
    if ($r * 2 -gt $w) { $r = $w / 2 }
    if ($r * 2 -gt $h) { $r = $h / 2 }
    $d = $r * 2
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

# Painted after the renderer has drawn the item background, so the row text is
# left empty and everything below is ours.
$RowPainter = {
    param($s, $e)
    $spec = $s.Tag
    if ($null -eq $spec) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $h = $s.Height

    if ($spec.Type -ne 'bar') {
        $color = if ($spec.Level -eq 'warn') { $COLOR_HOT } else { $CLR_MUTED }
        [System.Windows.Forms.TextRenderer]::DrawText(
            $g, [string]$spec.Text, $FONT_ROW,
            (New-Object System.Drawing.Rectangle($PAD_X, 0, ($s.Width - $PAD_X * 2), $h)),
            $color,
            ([System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
        return
    }

    $hasPct = ($null -ne $spec.Pct)
    $pct = if ($hasPct) { [int]$spec.Pct } else { 0 }
    $level = if ($hasPct) { Get-LevelColor $pct } else { $COLOR_DEAD }
    $barY = [int](($h - $BAR_THICK) / 2)

    $track = New-Object System.Drawing.SolidBrush($CLR_TRACK)
    $tp = New-RoundedPath $PAD_X $barY $BAR_PX $BAR_THICK ($BAR_THICK / 2)
    $g.FillPath($track, $tp)
    $tp.Dispose(); $track.Dispose()

    if ($hasPct -and $pct -gt 0) {
        $fillW = [int][math]::Round([math]::Min(100, $pct) / 100.0 * $BAR_PX)
        if ($fillW -lt $BAR_THICK) { $fillW = $BAR_THICK }   # keep 1% visible
        $fill = New-Object System.Drawing.SolidBrush($level)
        $fp = New-RoundedPath $PAD_X $barY $fillW $BAR_THICK ($BAR_THICK / 2)
        $g.FillPath($fill, $fp)
        $fp.Dispose(); $fill.Dispose()
    }

    $x = $PAD_X + $BAR_PX + $GAP
    $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::Right
    $pctText = if ($hasPct) { "$pct%" } else { '--' }
    [System.Windows.Forms.TextRenderer]::DrawText(
        $g, $pctText, $FONT_PCT,
        (New-Object System.Drawing.Rectangle($x, 0, $PCT_PX, $h)), $level, $flags)

    $x += $PCT_PX + $GAP
    $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText(
        $g, [string]$spec.Name, $FONT_ROW,
        (New-Object System.Drawing.Rectangle($x, 0, $script:NameColPx, $h)), $CLR_TEXT, $flags)

    if ($spec.Tail) {
        $x += $script:NameColPx + $GAP
        [System.Windows.Forms.TextRenderer]::DrawText(
            $g, [string]$spec.Tail, $FONT_ROW,
            (New-Object System.Drawing.Rectangle($x, 0, ($s.Width - $x - $PAD_X), $h)), $CLR_MUTED, $flags)
    }
}

# Preallocated non-clickable rows, toggled by Set-Rows (mirrors ROW_SLOTS upstream).
$rowItems = @()
for ($i = 0; $i -lt $ROW_SLOTS; $i++) {
    $lbl = New-Object System.Windows.Forms.ToolStripMenuItem('')
    $lbl.Visible = $false
    # A dropdown sizes itself from its items' preferred size, and an item with
    # AutoSize off is still stretched to the dropdown width - so width is
    # requested with a run of invisible no-break spaces (see Set-Rows) and the
    # real content is painted over it.
    $lbl.AutoSize = $true
    $lbl.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
    $lbl.Tag = $null
    $lbl.Add_Paint($RowPainter)
    # Rows are labels, not commands: they stay readable but do nothing on click.
    $lbl.Add_Click({ param($s, $e) })
    [void]$menu.Items.Add($lbl)
    $rowItems += $lbl
}
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miRefresh = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh')
$miDetails = New-Object System.Windows.Forms.ToolStripMenuItem('Show details')
$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Run at startup')
$miStartup.CheckOnClick = $true
$miStartup.Checked = Test-Autostart
$miQuit    = New-Object System.Windows.Forms.ToolStripMenuItem('Quit')
[void]$menu.Items.Add($miRefresh)
[void]$menu.Items.Add($miDetails)
[void]$menu.Items.Add($miStartup)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miQuit)

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.ContextMenuStrip = $menu
# Icon and tooltip must be set before Visible, or the shell gets an NIM_ADD with
# no icon and the entry never shows up in the tray.
$notify.Icon = New-TrayIcon 0 $false $true
$notify.Text = "$APP_TITLE ..."
$notify.Visible = $true

# Last successful snapshot + pending one-shot retry, so a failed poll keeps
# showing good data instead of blanking the menu.
$script:LastView    = $null
$script:LastRaw     = ''
$script:LastError   = $null
$script:Details     = "${APP_TITLE}: starting..."
$script:WasWarning  = $false
$script:Fetching    = $false
$script:PowerShell  = $null
$script:Handle      = $null
$script:Runspace    = $null
$script:RetryDue    = $null
# Consecutive 429s, used to widen the retry gap while the API is throttling us.
$script:RateLimitStreak = 0

# A row spec is either
#   @{ Type = 'bar';  Name; Pct; Tail }        - colored progress row
#   @{ Type = 'note'; Text; Level }            - plain line (errors, extra usage)
function New-BarSpec($name, $pct, $reset) {
    $cd = Format-ResetCountdown $reset
    $tail = if ($cd) { [char]0x00B7 + '  resets in ' + $cd } else { '' }
    return @{ Type = 'bar'; Name = $name; Pct = $pct; Tail = $tail }
}

function New-NoteSpec([string]$text, [string]$level) {
    return @{ Type = 'note'; Text = $text; Level = $level }
}

function Measure-RowText([string]$text, $font) {
    if ([string]::IsNullOrEmpty($text)) { return 0 }
    return [System.Windows.Forms.TextRenderer]::MeasureText(
        $text, $font, (New-Object System.Drawing.Size(4000, 40)),
        [System.Windows.Forms.TextFormatFlags]::NoPadding).Width
}

function Set-Rows($specs) {
    $specs = @($specs)
    # Column widths are measured, not padded with spaces, so the menu font does
    # not have to be monospaced for the columns to line up.
    $nameW = 40
    $tailW = 0
    $noteW = 0
    foreach ($s in $specs) {
        if ($s.Type -eq 'bar') {
            $w = Measure-RowText ([string]$s.Name) $FONT_ROW
            if ($w -gt $nameW) { $nameW = $w }
            $w = Measure-RowText ([string]$s.Tail) $FONT_ROW
            if ($w -gt $tailW) { $tailW = $w }
        } else {
            $w = Measure-RowText ([string]$s.Text) $FONT_ROW
            if ($w -gt $noteW) { $noteW = $w }
        }
    }
    $script:NameColPx = $nameW + 4
    $rowW = $PAD_X + $BAR_PX + $GAP + $PCT_PX + $GAP + $script:NameColPx + $PAD_X
    if ($tailW -gt 0) { $rowW += $GAP + $tailW }
    $noteRowW = $PAD_X * 2 + $noteW
    if ($noteRowW -gt $rowW) { $rowW = $noteRowW }
    if ($rowW -gt 640) { $rowW = 640 }

    # Reserve the width with no-break spaces: they measure like real text, so
    # the dropdown grows to fit, and they render as nothing under the painter.
    $nbsp = [string][char]0x00A0
    $unit = Measure-RowText ($nbsp * 20) $menu.Font
    if ($unit -le 0) { $unit = 20 * 5 }
    $count = [int][math]::Ceiling($rowW / ($unit / 20.0))
    $filler = $nbsp * [math]::Max(1, $count)

    for ($i = 0; $i -lt $rowItems.Count; $i++) {
        if ($i -lt $specs.Count) {
            $rowItems[$i].Tag = $specs[$i]
            $rowItems[$i].Text = $filler
            $rowItems[$i].Visible = $true
            $rowItems[$i].Invalidate()
        } else {
            $rowItems[$i].Tag = $null
            $rowItems[$i].Text = ''
            $rowItems[$i].Visible = $false
        }
    }
}

function Build-RowSpecs($view) {
    $specs = @()
    foreach ($r in $view.Rows) { $specs += New-BarSpec $r.Name $r.Pct $r.Reset }
    if ($view.Spend) { $specs += New-NoteSpec ([string]$view.Spend) 'muted' }
    return $specs
}

function Set-Tooltip([string]$text) {
    # NotifyIcon.Text throws above 63 characters on .NET Framework.
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
    $notify.Text = $text
}

Set-Rows @((New-NoteSpec "${APP_TITLE}: starting..." 'muted'))

function Start-Fetch {
    if ($script:Fetching) { return }
    $token = $null
    try {
        $token = Read-Token
    } catch {
        Apply-Error $_.Exception.Message $false
        return
    }
    $cfg = @{
        Endpoint = $ENDPOINT; Beta = $BETA_HEADER; Token = $token
        TimeoutSec = $TIMEOUT; Attempts = $FETCH_ATTEMPTS
    }
    $script:Runspace = [runspacefactory]::CreateRunspace()
    $script:Runspace.ApartmentState = 'MTA'
    $script:Runspace.ThreadOptions = 'ReuseThread'
    $script:Runspace.Open()
    $script:PowerShell = [powershell]::Create()
    $script:PowerShell.Runspace = $script:Runspace
    [void]$script:PowerShell.AddScript($Worker.ToString()).AddArgument($cfg)
    $script:Handle = $script:PowerShell.BeginInvoke()
    $script:Fetching = $true
}

function Complete-Fetch {
    $result = $null
    try {
        $out = $script:PowerShell.EndInvoke($script:Handle)
        if ($out -and $out.Count -gt 0) { $result = $out[$out.Count - 1] }
    } catch {
        $result = @{ Ok = $false; Error = "worker failed: $($_.Exception.Message)"; Transient = $true }
    } finally {
        try { $script:PowerShell.Dispose() } catch { }
        try { $script:Runspace.Close(); $script:Runspace.Dispose() } catch { }
        $script:PowerShell = $null; $script:Runspace = $null; $script:Handle = $null
        $script:Fetching = $false
    }

    if ($null -eq $result) { Apply-Error 'worker returned nothing' $true; return }
    if (-not $result.Ok) {
        $after = $null
        try { if ($null -ne $result.RetryAfter) { $after = [double]$result.RetryAfter } } catch { }
        $limited = $false
        try { $limited = [bool]$result.RateLimited } catch { }
        if ($limited) {
            # Each consecutive 429 doubles the wait (60s, 2m, 4m ... 10m cap) so
            # a long throttle is ridden out quietly instead of re-asked every
            # minute. Any successful poll resets the streak.
            $script:RateLimitStreak = [int]$script:RateLimitStreak + 1
            $factor = [math]::Pow(2, [math]::Min($script:RateLimitStreak - 1, 8))
            $scaled = $after * $factor
            if ($scaled -gt 600) { $scaled = 600 }
            $after = $scaled
        } else {
            $script:RateLimitStreak = 0
        }
        Apply-Error ([string]$result.Error) ([bool]$result.Transient) $after $limited
        return
    }

    try {
        $payload = $result.Raw | ConvertFrom-Json
    } catch {
        # A truncated body or a gateway HTML error page - treat as transient.
        Apply-Error "bad JSON from usage endpoint: $($_.Exception.Message)" $true
        return
    }
    try { $view = Build-View $payload } catch { Apply-Error "unexpected usage JSON shape: $($_.Exception.Message)" $false; return }
    Apply-Ok $view ([string]$result.Raw)
}

function Apply-Ok($view, [string]$raw) {
    $script:RetryDue = $null
    $script:RateLimitStreak = 0
    $script:LastView = $view
    $script:LastRaw = $raw
    $script:LastError = $null
    $script:Details = Format-DetailsText $view
    Set-Rows (Build-RowSpecs $view)
    $label = Format-PanelLabel $view
    Set-Tooltip $label
    Set-TrayIcon $notify ([int]$view.Peak) ([bool]$view.Warn) $false

    if ($NOTIFY -and $view.Warn -and -not $script:WasWarning) {
        try { $notify.ShowBalloonTip(10000, $APP_TITLE, $label, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
    }
    $script:WasWarning = [bool]$view.Warn
}

# The menu note is a single line, so any multi-line message (an exception, a
# stray JSON body) is flattened before it can wrap the panel.
function Format-NoteLine([string]$text, [int]$max) {
    if ($null -eq $text) { return '' }
    $one = ($text -replace '\s+', ' ').Trim()
    if ($one.Length -gt $max) { $one = $one.Substring(0, $max - 1).TrimEnd() + [string][char]0x2026 }
    return $one
}

function Apply-Error([string]$message, [bool]$transient, $retryAfter = $null, [bool]$showNextTry = $false) {
    # Transient failures retry soon; auth/other failures back off further so we
    # do not hammer a dead token (it recovers when Claude Code refreshes it).
    $delay = if ($transient) { $RETRY_SECONDS } else { $RETRY_SECONDS * 4 }
    # A 429 with Retry-After tells us exactly when the window opens; waiting less
    # than that only earns another 429, so honour it (capped so the tray does not
    # go quiet for hours on a bogus header).
    if ($null -ne $retryAfter) {
        $hinted = [double]$retryAfter
        if ($hinted -gt 3600) { $hinted = 3600 }
        if ($hinted -gt $delay) { $delay = $hinted }
    }
    $script:RetryDue = (Get-Date).AddSeconds($delay)
    # Say when we will ask again, computed from the delay actually scheduled.
    if ($showNextTry) {
        $secs = [int][math]::Ceiling($delay)
        $when = if ($secs -ge 60) { '' + [int][math]::Round($secs / 60.0) + 'm' } else { "${secs}s" }
        $message = "$message - next try in $when"
    }

    $script:LastError = $message
    $view = $script:LastView
    if ($null -ne $view) {
        # A single failed poll must not blank the tray. Keep the last good
        # numbers visible, note the failure at the foot of the menu, and let the
        # retry timer recover - most blips clear within one try.
        $rows = @(Build-RowSpecs $view)
        $note = Format-NoteLine ($WARN + 'last update failed - retrying ' + [char]0x00B7 + ' ' + $message) 100
        $rows += New-NoteSpec $note 'warn'
        Set-Rows $rows
        Set-Tooltip (Format-PanelLabel $view)
        Set-TrayIcon $notify ([int]$view.Peak) ([bool]$view.Warn) $false
        $script:Details = (Format-DetailsText $view) + "`r`n`r`n" + $WARN + "last update failed: $message"
    } else {
        # No good data yet (e.g. first poll on a dead token) - surface it.
        $line = Format-NoteLine ($WARN + "ERROR: $message") 100
        Set-Rows @((New-NoteSpec $line 'warn'))
        Set-Tooltip ($WARN + 'error')
        Set-TrayIcon $notify 0 $false $true
        $script:Details = "${APP_TITLE}: ERROR: $message"
    }
}

# --------------------------------------------------------------------- timers
# One 500 ms tick drives everything: worker completion, the refresh cycle and
# the one-shot retry. WinForms timers fire on the UI thread, so every handler
# above touches controls safely.
$script:NextPoll = Get-Date
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try {
        if ($script:Fetching) {
            if ($script:Handle.IsCompleted) {
                Complete-Fetch
                $script:NextPoll = (Get-Date).AddSeconds($REFRESH_SECONDS)
                # A back-off longer than the refresh cycle must win, or the
                # regular poll would fire first and undo the wait.
                if ($null -ne $script:RetryDue -and $script:RetryDue -gt $script:NextPoll) {
                    $script:NextPoll = $script:RetryDue
                }
            }
            return
        }
        $now = Get-Date
        if ($null -ne $script:RetryDue -and $now -ge $script:RetryDue) {
            $script:RetryDue = $null
            Start-Fetch
            return
        }
        if ($now -ge $script:NextPoll) {
            $script:NextPoll = $now.AddSeconds($REFRESH_SECONDS)
            Start-Fetch
        }
    } catch {
        # A handler must never throw into the message loop.
        try { Apply-Error "internal: $($_.Exception.Message)" $true } catch { }
    }
})
$timer.Start()

# ------------------------------------------------------------------- actions
$miRefresh.Add_Click({
    $script:RetryDue = $null
    $script:NextPoll = (Get-Date).AddSeconds($REFRESH_SECONDS)
    Start-Fetch
})

# Double-click on the tray icon refreshes (upstream uses middle-click).
$notify.Add_MouseDoubleClick({
    param($s, $e)
    $script:RetryDue = $null
    $script:NextPoll = (Get-Date).AddSeconds($REFRESH_SECONDS)
    Start-Fetch
})

$miDetails.Add_Click({
    try {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('limitschecker-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        $text = $script:Details
        if ($script:LastRaw) {
            $pretty = $script:LastRaw
            try { $pretty = $script:LastRaw | ConvertFrom-Json | ConvertTo-Json -Depth 12 } catch { }
            $text += "`r`n`r`n--- raw usage JSON ---`r`n" + $pretty
        }
        Set-Content -LiteralPath $path -Value $text -Encoding UTF8
        Start-Process -FilePath 'notepad.exe' -ArgumentList $path
    } catch {
        [System.Windows.Forms.MessageBox]::Show("cannot show details: $($_.Exception.Message)", $APP_TITLE) | Out-Null
    }
})

$miStartup.Add_Click({
    try {
        Set-Autostart ([bool]$miStartup.Checked)
    } catch {
        $miStartup.Checked = Test-Autostart
        [System.Windows.Forms.MessageBox]::Show("cannot change autostart: $($_.Exception.Message)", $APP_TITLE) | Out-Null
    }
})

$miQuit.Add_Click({
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

Start-Fetch
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
try { $mutex.ReleaseMutex() } catch { }
