# TrueNAS SCALE App Updater

A shell script that uses the TrueNAS SCALE 25.04 REST API to check for and apply app updates.

---

## Requirements

- `curl`
- `jq`

Both must be available in your `PATH` on the machine running the script.

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
| `-h`, `--host HOST` | TrueNAS hostname or IP | `$TRUENAS_HOST` |
| `-k`, `--api-key KEY` | API key | `$TRUENAS_API_KEY` |
| `-d`, `--dry-run` | List available updates without applying them | off |
| `-y`, `--yes` | Skip the confirmation prompt | off |
| `-n`, `--no-confirm` | Skip the confirmation prompt and print a structured results summary to stdout | off |
| `--probe-api` | Print all available `/app/*` REST endpoints from the TrueNAS OpenAPI schema and exit (useful for debugging 404 errors) | off |
| `--no-verify-ssl` | Disable SSL certificate verification (for self-signed certs) | off |
| `--timeout SECS` | Per-request curl timeout in seconds | `30` |
| `--job-timeout SECS` | Max seconds to wait for an upgrade job to complete | `600` |
| `--retries N` | Number of times to retry a failed upgrade before giving up | `3` |
| `--retry-delay SECS` | Seconds to wait between retry attempts | `15` |

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `TRUENAS_HOST` | Base URL of your TrueNAS instance, e.g. `https://192.168.1.100` |
| `TRUENAS_API_KEY` | API key generated in the TrueNAS UI |

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
./truenas-update-apps.sh --host https://192.168.1.100 --api-key mykey --no-verify-ssl

# Dry-run for a single app with a longer job timeout
./truenas-update-apps.sh --dry-run --job-timeout 900 sonarr

# Discover available /app/* REST endpoints (useful when upgrades return 404)
./truenas-update-apps.sh --probe-api

# Disable retries (fail immediately on first error)
./truenas-update-apps.sh --retries 0

# Increase retries for a flaky network, with a longer wait between attempts
./truenas-update-apps.sh --retries 5 --retry-delay 30
```

---

## How It Works

| Step | API Endpoint |
|------|--------------|
| Verify connectivity | `GET /api/v2.0/system/info` |
| List installed apps | `GET /api/v2.0/app` |
| Filter upgradeable apps | Client-side via `jq` (`upgrade_available == true`) |
| Start upgrade (tried in order, first success wins) | See below |
| Poll job status | `GET /api/v2.0/core/get_jobs?id={job_id}` |
| Fetch failure log (on job error) | `GET /api/v2.0/filesystem/get?path=<log_path>` |

### Upgrade endpoint fallback chain

TrueNAS SCALE 25.04 exposes different upgrade endpoints depending on whether an app has a new catalog version or only new Docker image tags. The script tries each in order until one succeeds:

| # | Endpoint | Body | Use case |
|---|----------|------|----------|
| A | `POST /app/{name}/upgrade` | `{}` | New app definition version in the TrueNAS catalog |
| B | `POST /app/{name}/pull_images` | `{"redeploy": true}` | New Docker image tags, same app definition version |
| C | `POST /app/upgrade` | `{"app_name": "…"}` | Alternative REST mapping used by some 25.04 builds |
| D | `POST /app/pull_images` | `{"app_name": "…", "options": {"redeploy": true}}` | Alternative image-pull mapping |

### Automatic log fetching on failure

When TrueNAS reports a job failure and the error message references a log file (e.g. `/var/log/app_lifecycle.log`), the script automatically fetches the last 40 lines of that file via the TrueNAS filesystem API and prints them inline. If the API fetch fails, it prints the equivalent SSH command instead:

```
ssh root@nas.pfrem.me "tail -50 /var/log/app_lifecycle.log"
```

### Stopped-app handling

Before upgrading any app whose state is `STOPPED`, the script calls `POST /api/v2.0/app/{name}/start` and waits for it to finish. If the start fails for any reason the upgrade is still attempted — the start step is non-fatal.

### Iterative upgrade passes

After every pass the script re-checks TrueNAS for new `upgrade_available` apps (up to **10 passes**). This handles cases where updating one app unlocks an update for another. The loop stops when:

- TrueNAS reports no more upgradeable apps, **or**
- A full pass produces zero successful upgrades (persistent failure — no point retrying), **or**
- 10 passes are reached (safety guard)

The confirmation prompt is shown **once** before the first pass only.

Updates within each pass are applied sequentially. The script polls each upgrade job until it reports `SUCCESS`, `FAILED`, or `ABORTED`, or until `--job-timeout` is reached.

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

This makes it easy to capture or pipe just the results while letting the normal progress log go to a separate file.

---

## Cron Example

Run every night at 3 AM. Use `--no-confirm` to capture a clean results summary in its own log, with full progress detail going to a separate file:

```cron
# Full progress log + results summary in one file
0 3 * * * TRUENAS_HOST=https://192.168.1.100 TRUENAS_API_KEY=your-key /path/to/truenas-update-apps.sh --no-confirm >> /var/log/truenas-updates.log 2>&1

# Or use --yes if you only want the progress log (no results block)
0 3 * * * TRUENAS_HOST=https://192.168.1.100 TRUENAS_API_KEY=your-key /path/to/truenas-update-apps.sh --yes >> /var/log/truenas-updates.log 2>&1
```
