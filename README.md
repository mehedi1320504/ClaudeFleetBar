# Claude Fleet Bar

A macOS menu bar app that answers one question for people running **several Claude
Code accounts**: *which one should I run next, and when does the next one free up?*

It auto-detects every `~/.claude-account-*` config dir, reads each account's usage
**live**, and ranks them by real headroom — 5-hour window, weekly window, and the
countdown to each reset.

> **Why not just read the CLI's cache?** Claude Code stores its last-known usage in
> `<config-dir>/.claude.json` under `cachedUsageUtilization`, but it only writes that
> when the account actually runs a session. On a 5-account fleet, two dirs had numbers
> more than a day stale and two had none at all — one account's cache read 62% weekly
> while the live figure was 10%. A file-only widget quietly tells you the wrong thing,
> so this app fetches live and labels any cached fallback with its age.

## Features

- **Auto-detects accounts.** Anything matching `~/.claude-account-*`, plus `~/.claude`.
  A sixth account works the moment you create it — no config to maintain.
- **Live 5-hour and weekly usage** with utilization rings and reset countdowns.
- **A run order**, not just numbers: headroom is `100 − max(5h, weekly)`, ties break
  toward the lower weekly figure, since a 5-hour window refills in hours and a weekly
  one in days.
- **Transition-only alerts** when an account frees up, is nearly spent, or runs out.
  A notifier that fires every refresh is one you learn to ignore.
- **Read-only, always.** Credentials are read from the login Keychain and never
  written, refreshed or deleted. An expired token is reported, not repaired.
- **JSON export** to `~/.cache/claude-fleet-bar/usage.json` so scripts can rank
  accounts by measured headroom instead of probing blind.

## Install

Requires macOS 14+ and the Xcode toolchain.

```sh
git clone https://github.com/mehedi1320504/ClaudeFleetBar.git
cd ClaudeFleetBar
./scripts/build-app.sh
open dist/ClaudeFleetBar.app
```

macOS will ask for Keychain access once per account. Choose **Always Allow** so it
does not prompt on every launch.

To start it at login: System Settings → General → Login Items → add
`dist/ClaudeFleetBar.app`.

## CLI

`scripts/fleet-usage` reads the same exported snapshot:

```sh
fleet-usage board   # the full table
fleet-usage best    # just the account to run next, e.g. "b"
fleet-usage order   # "b c e a d"
fleet-usage json    # raw snapshot
```

Handy with a multi-account dispatcher:

```sh
CLAUDE_CONFIG_DIR="$HOME/.claude-account-$(fleet-usage best)" claude
```

## How it works

| Step | Detail |
| --- | --- |
| Discover | Scan `~` for `.claude-account-*` and `.claude` |
| Locate credentials | Claude Code keys its Keychain entry as `Claude Code-credentials-<first 8 hex of sha256(configDir)>`, so each config dir maps to its own item |
| Read token | `SecItemCopyMatching` → `claudeAiOauth.accessToken` (read-only) |
| Fetch usage | `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer …` and `anthropic-beta: oauth-2025-04-20` — the same endpoint the CLI uses to fill its own cache |
| Fall back | On an expired or unreadable token, show `cachedUsageUtilization` from `.claude.json`, **labelled with its age** |

Accounts are fetched concurrently, so one slow or broken account never holds up the board.

### What it never does

- Write to the Keychain, or touch the CLI's auth state.
- Spend tokens. The usage endpoint is free; this app never sends a message to measure
  a limit.
- Send your data anywhere. The only network call is to `api.anthropic.com`.

## Prior art

This exists because none of the good ones fit a fleet of CLI accounts:

- [dody87/ccam](https://github.com/dody87/ccam) — same data path (Keychain +
  `/api/oauth/usage`) and the source of the key-derivation detail, but CLI only.
- [rjwalters/claude-monitor](https://github.com/rjwalters/claude-monitor) — menu bar
  with a headroom score, but wants tokens pasted by hand and pings `/v1/messages`.
- [f-is-h/usage4claude](https://github.com/f-is-h/usage4claude) — menu bar, but keys
  off browser `sessionKey`s rather than CLI accounts.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Anthropic. `/api/oauth/usage` is an internal endpoint and may
change without notice.
