# LimitsChecker for Windows

*(На русском: [README.ru.md](README.ru.md))*

Tray indicator for **Claude Code usage limits** on Windows — a port of
[LimitsChecker](https://github.com/lapurryt/LimitsChecker) (GNOME/AppIndicator +
macOS menu bar). Same data layer (the Anthropic OAuth usage endpoint), rendered
through a WinForms `NotifyIcon`.

It shows the same limit windows as `/usage` inside Claude Code:

- `Session` — the rolling 5-hour session window
- `Week` — the 7-day weekly window (all activity)
- `<model>` — the 7-day per-model window, when it is active

**No dependencies**: just Windows PowerShell 5.1 and the .NET Framework that
ship with Windows 10/11. No Python, nothing to install.

## What it looks like

On macOS/GNOME the string `Session 5% · Week 42% · Fable 59%` is drawn straight
into the panel. The Windows tray cannot show text, so:

- **icon** — the highest percentage, colored by threshold (green → yellow → red),
- **tooltip** — the same string, `Session 16% · Week 12%`,
- **menu** — rows with real colored progress bars and a countdown:

```
[====------]  16%  Session   ·  resets in 1h 40m
[===-------]  12%  Week      ·  resets in 2d 10h
[=---------]   2%  Fable     ·  resets in 2d 10h
```

The menu follows the Windows dark/light theme. Crossing the threshold (80% by
default), or an abnormal severity reported by the API, turns the icon red, adds
`⚠` to the tooltip and raises a balloon notification once.

**Double-click** the icon to refresh immediately; **Show details** opens the
breakdown and the raw JSON response in Notepad.

## How it works

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken from %USERPROFILE%\.claude\.credentials.json>
anthropic-beta: oauth-2025-04-20
```

The primary source is the `limits[]` array (`session`, `weekly_all`,
`weekly_scoped`); `five_hour` / `seven_day` are used as a fallback. The token is
re-read from disk **on every poll**, so a background token refresh performed by
Claude Code itself is picked up without a restart. A dead token shows up as a
401 from the endpoint (sign in to Claude again). The OAuth token needs the
`user:profile` scope — Claude Code logins have it.

If `.credentials.json` is missing, a generic entry from the Windows Credential
Manager is read instead (target name from `LIMITSCHECKER_CREDENTIAL_TARGET`) —
the equivalent of the macOS keychain path.

The network call runs in a background runspace, so a slow response never freezes
the menu. A single failed poll does not blank the numbers: the last good values
stay, an error line appears at the bottom of the menu, and the next attempt
happens after `RETRY_SECONDS` (four times longer for 401). 5xx is treated as
transient and retried inside the poll; a 429 skips those extra attempts and
widens the gap instead (1m, 2m, 4m, 8m, up to 10m), honoring `Retry-After`.

Each good poll is cached, so a restart shows the last known numbers right away
— marked with their age — instead of an empty panel while the first poll runs.

The endpoint admits roughly one request every two minutes per token, which is
why the default poll interval is three minutes. Lowering `REFRESH_SECONDS`
below that trades fresher numbers for a 429 on every other poll.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (`powershell.exe`, present by default)
- Claude Code, signed in (`%USERPROFILE%\.claude\.credentials.json` exists)

## Run

```powershell
# one-off, without installing (no console window)
wscript.exe LimitsChecker.vbs

# or directly
powershell -NoProfile -ExecutionPolicy Bypass -File LimitsChecker.ps1
```

## Install

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer copies the files to `%LOCALAPPDATA%\LimitsChecker`, drops a
shortcut into the Startup folder (`shell:startup`) and launches the app. No
admin rights needed. Flags: `-NoAutostart`, `-NoLaunch`.

Autostart can also be toggled from the menu — **Run at startup**.

The icon lands in the tray overflow area; to pin it to the taskbar go to
Settings → Personalization → Taskbar → Other system tray icons.

## Verify

```powershell
# a single synchronous poll printed to the console, no tray
powershell -NoProfile -ExecutionPolicy Bypass -File LimitsChecker.ps1 -SelfTest

# raw data
$t = (Get-Content "$env:USERPROFILE\.claude\.credentials.json" -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
Invoke-RestMethod https://api.anthropic.com/api/oauth/usage -Headers @{
    Authorization = "Bearer $t"; 'anthropic-beta' = 'oauth-2025-04-20' } | ConvertTo-Json -Depth 8
```

## Configuration

Environment variables. Both prefixes work: `LIMITSCHECKER_*` (takes precedence)
and `CLAUDEBAR_*`, as in the Linux version. A malformed value falls back to the
default and is clamped to its range, so a stray variable never blocks startup.

| Variable | Default | Meaning |
| --- | --- | --- |
| `..._CREDENTIALS` | `%USERPROFILE%\.claude\.credentials.json` | Path to the Claude OAuth credentials |
| `..._CREDENTIAL_TARGET` | `Claude Code-credentials` | Credential Manager entry name (fallback token source) |
| `..._ENDPOINT` | `https://api.anthropic.com/api/oauth/usage` | Usage endpoint |
| `..._BETA` | `oauth-2025-04-20` | Value of the `anthropic-beta` header |
| `..._REFRESH_SECONDS` | `180` | Poll interval, seconds (minimum 5) |
| `..._RETRY_SECONDS` | `30` | Pause before retrying after a failure, seconds |
| `..._FETCH_ATTEMPTS` | `3` | Attempts within one poll (1–10) |
| `..._TIMEOUT` | `30` | HTTP timeout, seconds |
| `..._WARN_PERCENT` | `80` | Threshold for ⚠ and the red color (0–100) |
| `..._SHOW_SCOPED` | `1` | Show the per-model window in the tooltip |
| `..._SCOPED_INACTIVE` | `0` | Show the per-model window even when the API marks it inactive |
| `..._NOTIFY` | `1` | Balloon notification when the threshold is crossed |
| `..._THEME` | `auto` | `auto` \| `dark` \| `light` — menu theme |
| `..._MENU_FONT` | `Segoe UI` | Menu font |
| `..._BAR_PX` | `92` | Colored bar length in the menu, pixels |
| `..._BAR_WIDTH` | `10` | Text bar width (`-SelfTest`, details window) |
| `..._FILL_CHAR` / `..._TRACK_CHAR` | `█` / `▒` | Text bar glyphs |
| `..._NAME_SESSION` / `..._NAME_WEEK` | `Session` / `Week` | Window labels |
| `..._ICON` | — | Path to a custom `.ico` instead of the drawn icon |
| `..._TITLE` | `LimitsChecker` | App and details-window title |
| `..._CACHE` | `%LOCALAPPDATA%\LimitsChecker\usage-cache.json` | Last good payload, shown at startup while the first poll runs |

To make the variables apply to the autostarted instance too, set them for the
user:

```powershell
[Environment]::SetEnvironmentVariable('LIMITSCHECKER_WARN_PERCENT', '70', 'User')
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Removes the Startup shortcut, stops the app and deletes
`%LOCALAPPDATA%\LimitsChecker`.

## Differences from the original

- Menu progress bars are real owner-drawn graphics with color, not block glyphs —
  WinForms has no DBusMenu limitation. Text bars remain in `-SelfTest` and the
  details window.
- No panel string (the Windows tray cannot show text) — it moved to the tooltip,
  and the number is drawn onto the icon.
- Refresh on double-click instead of middle-click.
- Added: an autostart toggle in the menu, Windows theme following, and a balloon
  notification on threshold crossing.

## Credits

Port of [lapurryt/LimitsChecker](https://github.com/lapurryt/LimitsChecker) by
Anton Shalin — the GNOME/macOS original this project follows.

## License

MIT, same as the original project. See [LICENSE](LICENSE).
