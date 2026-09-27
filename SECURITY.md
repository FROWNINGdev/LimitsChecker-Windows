# Security Policy

## Reporting a vulnerability

Please report security issues privately, not in a public issue.

Use GitHub's **[Report a vulnerability](https://github.com/FROWNINGdev/LimitsChecker-Windows/security/advisories/new)** button (Security → Advisories) to open a private report. You will get an acknowledgement within a few days.

This tool reads the Anthropic OAuth usage API with a token stored on the local machine. When reporting, please note anything touching:

- how the OAuth token is read, stored, or logged;
- the tray process running with unexpected privileges;
- any network call to a host other than the Anthropic API.

Please do not include a real token in your report — redact it.

## Supported versions

Only the latest release on `main` receives fixes.
