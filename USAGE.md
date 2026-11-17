# TrueNAS SCALE App Updater

A shell script that uses the TrueNAS **JSON-RPC 2.0 over WebSocket API** (SCALE
25.04+; endpoint `/api/current`) to check for and apply app updates.

API reference: <https://api.truenas.com/v25.10/jsonrpc.html>

---

## Minimum TrueNAS Version

> **Requires TrueNAS SCALE 25.04 (Fangtooth) or newer.**
>
> 25.04 is the first release exposing the JSON-RPC 2.0 over WebSocket API at
> `/api/current`. TrueNAS 25.10 (Goldeye) **removed the legacy REST API**
> entirely, so older versions of this script stop working on 25.10; this
> version requires 25.04+ and no longer supports 24.10 (Electric Eel) or
> earlier REST-only releases.

---

## Requirements

- `jq`
- `python3`
- A Python WebSocket library — either:
  - `pip install websockets` (preferred), or
  - `pip install websocket-client`

All must be available in your `PATH` on the machine running the script.
(Note: `curl` is no longer needed.)

---

## Setup

### 1. Generate an API Key

In the TrueNAS UI, go to **top-right user menu → API Keys** and create a new key.

### 2. Provide Credentials

Export your credentials as environment variables (recommended for scripting and cron use):

```bash
export TRUENAS_HOST="https://192.168.1.100"
export TRUENAS_API_KEY="your-api-key-here"
```

A bare host or IP (`TRUENAS_HOST="192.168.1.100"`) also works — it is normalised
to `wss://192.168.1.100/api/current`. `http://` becomes `ws://`.

Alternatively, pass them directly via flags on each invocation (see [Options](#options)).

### 3. Make the Script Executable

```bash
chmod +x truenas-update-apps.sh
```

---

## Usage

```
./truenas-update-apps.sh [options] [app_name ...]
```

If no `app_name` arguments are given, all apps with available updates are targeted.

---

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `-h`, `--host HOST` | TrueNAS host (`https://host[:port]`, bare host/IP, or `wss://` URI) | `$TRUENAS_HOST` |
| `-k`, `--api-key KEY` | API key | `$TRUENAS_API_KEY` |
| `-d`, `--dry-run` | List available updates without applying them | off |
| `-y`, `--yes` | Skip the confirmation prompt | off |
| `-n`, `--no-confirm` | Skip the confirmation prompt and print a structured results summary to stdout | off |
| `--probe-api` | Print all `app.*` JSON-RPC methods and exit (debugging) | off |
| `--no-verify-ssl` | Disable SSL certificate verification (for self-signed certs) | off |
| `--timeout SECS` | Per-call WebSocket timeout in seconds | `30` |
| `--job-timeout SECS` | Max seconds to wait for an upgrade job to complete | `600` |
| `--retries N` | Number of times to retry a failed upgrade before giving up | `3` |
| `--retry-delay SECS` | Seconds to wait between retry attempts | `15` |

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `TRUENAS_HOST` | Base URL or host of your TrueNAS instance, e.g. `https://192.168.1.100` |
| `TRUENAS_API_KEY` | API key generated in the TrueNAS UI |
| `TRUENAS_API_PATH` | WebSocket API path (default `/api/current`; override only if your deployment differs) |

Flags passed on the command line take precedence over environment variables.

---

## Examples

```bash
# Check for updates and apply all of them (with confirmation prompt)
./truenas-update-apps.sh

# Preview what would be updated — no changes made
./truenas-update-apps.sh --dry-run

# Apply all updates, skip the confirmation prompt (suitable for cron)
./truenas-update-apps.sh --yes

# Skip confirmation and print a structured results summary to stdout
# Useful for capturing or piping output to another tool
./truenas-update-apps.sh --no-confirm

# Capture the results report to a file
./truenas-update-apps.sh --no-confirm > results.txt

# Update only specific apps
./truenas-update-apps.sh plex jellyfin

# Specify credentials inline and skip SSL verification
./truenas-update-apps.sh --host 192.168.1.100 --api-key mykey --no-verify-ssl

# Dry-run for a single app with a longer job timeout
./truenas-update-apps.sh --dry-run --job-timeout 900 sonarr

# List every app.* method the server exposes (debugging)
./truenas-update-apps.sh --probe-api

# Disable retries (fail immediately on first error)
./truenas-update-apps.sh --retries 0

# Increase retries for a flaky network, with a longer wait between attempts
./truenas-update-apps.sh --retries 5 --retry-delay 30
```

---

## How It Works

All communication is JSON-RPC 2.0 over a WebSocket connection
(`wss://<host>/api/current`), authenticated once per call with
`auth.login_with_api_key`:

| Step | JSON-RPC method |
|------|-----------------|
| Verify connectivity | `system.info` |
| List installed apps | `app.query` |
| Filter upgradeable apps | Client-side via `jq` (`upgrade_available == true`) |
| Start upgrade | `app.upgrade` (a job — blocks until done, progress streamed live) |
| Start a stopped app | `app.start` (also a job) |
| Fetch failure log excerpt | `core.get_jobs` (`logs_excerpt`) |

### Job progress

`app.upgrade` and `app.start` are server-side jobs. The script keeps the
WebSocket open while the job runs and renders live progress (state/percent,
from the `core.get_jobs` collection events) as it arrives, then confirms
completion when the final JSON-RPC result lands.

### Automatic log excerpt on failure

When an upgrade job fails, the script looks up the job via `core.get_jobs` and
prints the middleware-captured `logs_excerpt` inline (last 40 lines). If
TrueNAS captured no excerpt, it prints a hint pointing at the TrueNAS UI (Jobs)
and an equivalent `ssh tail` command.

### Stopped-app handling

Before upgrading any app whose state is `STOPPED`, the script calls
`app.start` and waits for it to finish. If the start fails for any reason the
upgrade is still attempted — the start step is non-fatal.

### Error classification

JSON-RPC errors are flattened from the standard error envelope
(`code` / `message` / `data.reason` / `data.errname`) and classified:

- `[EINVAL]` configuration errors → no retry (fix in the TrueNAS UI first)
- "stopped state" errors → the app is started, then the upgrade retried
- anything else → retried up to `--retries` times

### Iterative upgrade passes

After every pass the script re-checks TrueNAS for new `upgrade_available`
apps (up to **10 passes**). This handles cases where updating one app unlocks
an update for another. The loop stops when:

- TrueNAS reports no more upgradeable apps, **or**
- A full pass produces zero successful upgrades (persistent failure — no point retrying), **or**
- 10 passes are reached (safety guard)

The confirmation prompt is shown **once** before the first pass only.

Updates within each pass are applied sequentially.

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All targeted updates succeeded, or nothing needed updating |
| `1` | One or more upgrades failed, or a fatal error occurred |

---

## `--yes` vs `--no-confirm`

Both flags skip the interactive confirmation prompt, but they differ in output behaviour:

| Flag | Skips prompt | Prints structured results to stdout |
|------|:---:|:---:|
| `--yes` / `-y` | yes | no |
| `--no-confirm` / `-n` | yes | **yes** |

`--no-confirm` appends a plain-text results block to stdout after all upgrades finish:

```
============================================================
TRUENAS APP UPDATE RESULTS — 2026-03-04 03:00:12
============================================================
Succeeded : 3
  + plex
  + jellyfin
  + sonarr
Failed    : 1
  - radarr
============================================================
```

This makes it easy to capture or pipe just the results while letting the
normal progress log go to a separate file.

---

## Cron Example

Run every night at 3 AM. Use `--no-confirm` to capture a clean results summary
in its own log, with full progress detail going to a separate file:

```cron
# Full progress log + results summary in one file
0 3 * * * TRUENAS_HOST=192.168.1.100 TRUENAS_API_KEY=your-key /path/to/truenas-update-apps.sh --no-confirm >> /var/log/truenas-updates.log 2>&1

# Or use --yes if you only want the progress log (no results block)
0 3 * * * TRUENAS_HOST=192.168.1.100 TRUENAS_API_KEY=your-key /path/to/truenas-update-apps.sh --yes >> /var/log/truenas-updates.log 2>&1
```
