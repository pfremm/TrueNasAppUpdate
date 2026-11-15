#!/usr/bin/env bash
# ==============================================================================
# truenas-update-apps.sh
# Check for and apply app updates via the TrueNAS JSON-RPC 2.0 over WebSocket
# API (TrueNAS SCALE 25.04+; endpoint /api/current).
#
#   API docs: https://api.truenas.com/v25.10/jsonrpc.html
#
# Usage:
#   ./truenas-update-apps.sh [options] [app_name ...]
#
# Options:
#   -h, --host HOST       TrueNAS host (https://host[:port] or bare host/IP)
#                         (overrides TRUENAS_HOST)
#   -k, --api-key KEY     API key (overrides TRUENAS_API_KEY)
#   -d, --dry-run         List updates but do not apply them
#   -y, --yes             Skip confirmation prompt
#   -n, --no-confirm      Skip confirmation and print a results summary to stdout
#       --probe-api       Print all app.* JSON-RPC methods and exit (debugging)
#       --no-verify-ssl   Disable SSL certificate verification
#       --timeout SECS    Per-call WebSocket timeout in seconds (default: 30)
#       --job-timeout SECS Max seconds to wait for an upgrade job (default: 600)
#       --retries N       Retry a failed upgrade N times before giving up (default: 3)
#       --retry-delay SECS Seconds to wait between retries (default: 15)
#   [app_name ...]        Only update the named apps (default: all updatable apps)
#
# Environment variables (used when flags are omitted):
#   TRUENAS_HOST          e.g. https://192.168.1.100 (bare host/IP also accepted)
#   TRUENAS_API_KEY       API key generated in TrueNAS UI → API Keys
#   TRUENAS_API_PATH      WebSocket API path (default: /api/current)
#
# Requirements:
#   jq, python3, and a Python WebSocket library: either `websockets`
#   (pip install websockets) or `websocket-client` (pip install websocket-client).
#
# Exit codes:
#   0  All targeted updates succeeded (or nothing to update)
#   1  One or more upgrades failed, or a fatal error occurred
# ==============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
TRUENAS_HOST="${TRUENAS_HOST:-}"
TRUENAS_API_KEY="${TRUENAS_API_KEY:-}"
TRUENAS_API_PATH="${TRUENAS_API_PATH:-/api/current}"
DRY_RUN=false
AUTO_CONFIRM=false
PRINT_RESULTS=false
PROBE_API=false
VERIFY_SSL=true
CALL_TIMEOUT=30
JOB_TIMEOUT=600
RETRIES=3        # number of retry attempts after a failed upgrade job
RETRY_DELAY=15   # seconds to wait between retries
TARGET_APPS=()   # empty = all upgradeable apps

WS_URI=""        # full wss:// URI, built by build_ws_uri
WS_CLIENT=""     # path to the extracted python helper (cleaned up on exit)

# ── ANSI colours ──────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()    { printf '%b[INFO]%b  %s\n'  "$BLUE"   "$NC" "$*"; }
log_ok()      { printf '%b[OK]%b    %s\n'  "$GREEN"  "$NC" "$*"; }
log_warn()    { printf '%b[WARN]%b  %s\n'  "$YELLOW" "$NC" "$*"; }
log_error()   { printf '%b[ERROR]%b %s\n'  "$RED"    "$NC" "$*" >&2; }
log_header()  {
    printf '\n%b%s%b\n' "$BOLD$CYAN" "$*" "$NC"
    printf '%0.s─' {1..60}
    printf '\n'
}
die() { log_error "$*"; exit 1; }

cleanup() { [[ -n "$WS_CLIENT" && -f "$WS_CLIENT" ]] && rm -f "$WS_CLIENT"; }
trap cleanup EXIT

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--host)        TRUENAS_HOST="$2";    shift 2 ;;
            -k|--api-key)     TRUENAS_API_KEY="$2"; shift 2 ;;
            -d|--dry-run)     DRY_RUN=true;                          shift ;;
            -y|--yes)         AUTO_CONFIRM=true;                     shift ;;
            -n|--no-confirm)  AUTO_CONFIRM=true; PRINT_RESULTS=true; shift ;;
            --probe-api)      PROBE_API=true;                        shift ;;
            --no-verify-ssl)  VERIFY_SSL=false;                      shift ;;
            --timeout)        CALL_TIMEOUT="$2";    shift 2 ;;
            --job-timeout)    JOB_TIMEOUT="$2";     shift 2 ;;
            --retries)        RETRIES="$2";         shift 2 ;;
            --retry-delay)    RETRY_DELAY="$2";     shift 2 ;;
            -*)               die "Unknown option: $1" ;;
            *)                TARGET_APPS+=("$1");  shift ;;
        esac
    done
}

# ── Preflight checks ──────────────────────────────────────────────────────────
check_dependencies() {
    local missing=()
    for cmd in python3 jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"

    # Python WebSocket library: websockets (preferred) or websocket-client
    if ! python3 -c 'try:
    import websockets
except ImportError:
    import websocket' &>/dev/null; then
        die "No Python WebSocket library found. Install one of: pip install websockets  |  pip install websocket-client"
    fi
}

validate_config() {
    [[ -n "$TRUENAS_HOST"    ]] || die "TrueNAS host not set. Use --host or export TRUENAS_HOST."
    [[ -n "$TRUENAS_API_KEY" ]] || die "API key not set. Use --api-key or export TRUENAS_API_KEY."
    TRUENAS_HOST="${TRUENAS_HOST%/}"   # strip any trailing slash
}

# build_ws_uri
# Normalises TRUENAS_HOST into a full WebSocket URI:
#   https://nas.local        -> wss://nas.local/api/current
#   http://nas.local:8080    -> ws://nas.local:8080/api/current
#   wss://nas.local:8443     -> wss://nas.local:8443/api/current
#   192.168.1.100            -> wss://192.168.1.100/api/current
build_ws_uri() {
    local base="$TRUENAS_HOST"
    case "$base" in
        wss://*|ws://*) ;;
        https://*) base="wss://${base#https://}" ;;
        http://*)  base="ws://${base#http://}" ;;
        *)         base="wss://${base}" ;;
    esac
    WS_URI="${base}${TRUENAS_API_PATH}"
}

# ── WebSocket JSON-RPC 2.0 helper (embedded Python) ───────────────────────────
# The helper opens one connection per invocation, authenticates with the API
# key (auth.login_with_api_key), then performs exactly one operation.
#   stdout : the JSON result
#   stderr : PROGRESS lines streamed live as a job advances; human errors
#            plus a final "INFO {json}" line with structured details
write_ws_client() {
    WS_CLIENT=$(mktemp)
    cat > "$WS_CLIENT" <<'PYEOF'
#!/usr/bin/env python3
"""TrueNAS JSON-RPC 2.0 over WebSocket one-shot client.

Usage:
  ws_client.py call METHOD PARAMS_JSON TIMEOUT
  ws_client.py job  JOB_ID TIMEOUT

Env:
  WS_URI         full websocket URI (wss://host/api/current)
  WS_API_KEY     API key
  WS_VERIFY_SSL  "true"/"false"

Exit codes: 0 ok | 2 JSON-RPC error | 3 transport/connect failure | 4 timeout
"""
import asyncio
import json
import os
import ssl
import sys
import time

EXIT_OK, EXIT_RPC, EXIT_TRANSPORT, EXIT_TIMEOUT = 0, 2, 3, 4

URI = os.environ["WS_URI"]
API_KEY = os.environ["WS_API_KEY"]
VERIFY_SSL = os.environ.get("WS_VERIFY_SSL", "true") == "true"
ORIGIN = URI.split("/api/")[0]

MODE = sys.argv[1]
if MODE == "call":
    METHOD, PARAMS_JSON, TIMEOUT = sys.argv[2], sys.argv[3], float(sys.argv[4])
    PARAMS = json.loads(PARAMS_JSON) if PARAMS_JSON else []
elif MODE == "job":
    JOB_ID, TIMEOUT = int(sys.argv[2]), float(sys.argv[3])
else:
    print(f"unknown mode: {MODE}", file=sys.stderr)
    sys.exit(EXIT_TRANSPORT)

# Structured info for the bash layer (job id, progress, errors)
INFO = {}


def note_progress(jid, msg, state, percent, description):
    if isinstance(percent, float):
        percent = int(percent)
    print(f"PROGRESS job={jid} msg={msg} state={state} percent={percent} "
          f"desc={description}", file=sys.stderr, flush=True)
    INFO.update({"job_id": jid, "state": state, "percent": percent,
                 "description": description})


def flatten_error(err):
    """JSON-RPC error object -> flat dict for the bash layer."""
    data = err.get("data") or {}
    parts = [str(err.get("message") or "unknown error")]
    if data.get("reason"):
        parts.append(str(data["reason"]))
    if data.get("errname"):
        parts.append(f"[{data['errname']}]")
    for extra in (data.get("extra") or []):
        if isinstance(extra, dict):
            msg = extra.get("error_msg") or extra.get("message")
            if msg:
                parts.append(str(msg))
    return {
        "code": err.get("code"),
        "message": err.get("message"),
        "errname": data.get("errname"),
        "reason": data.get("reason"),
        "error_text": " — ".join(parts),
    }


def dump_info():
    """Emit the accumulated structured info as one JSON line on stderr."""
    if INFO:
        print("INFO " + json.dumps(INFO), file=sys.stderr, flush=True)


class Client:
    """Authenticates then performs one operation on a single websocket."""

    def __init__(self, op_timeout):
        self.op_timeout = op_timeout
        self.next_id = 0
        self.call_id = None
        self.job_id = None       # job tied to this call (matched via message_ids)
        self.response = None
        self._progress_key = None

    # ── transport ───────────────────────────────────────────────────────────
    def _connect(self):
        ctx = ssl.create_default_context()
        if not VERIFY_SSL:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        try:
            import websockets  # asyncio implementation
        except ImportError:
            return self._connect_websocket_client(ctx)
        return self._connect_websockets(ctx)

    def _connect_websockets(self, ctx):
        import websockets
        kwargs = {"ssl": ctx, "max_size": 64 * 1024 * 1024}
        try:  # websockets >= 14
            kwargs["additional_headers"] = {"Origin": ORIGIN}
        except TypeError:  # websockets < 14
            kwargs["extra_headers"] = {"Origin": ORIGIN}
        return websockets.connect(URI, **kwargs)

    def _connect_websocket_client(self, ctx):
        import websocket  # websocket-client, synchronous
        sslopt = {"cert_reqs": ssl.CERT_NONE} if not VERIFY_SSL else {}
        return websocket.create_connection(
            URI, timeout=self.op_timeout, sslopt=sslopt,
            header=[f"Origin: {ORIGIN}"])

    # ── receive loop ────────────────────────────────────────────────────────
    def _handle(self, raw):
        """Returns the response for our call id, or None to keep waiting."""
        try:
            resp = json.loads(raw)
        except ValueError:
            return None
        if resp.get("method") == "collection_update":
            p = resp.get("params") or {}
            if p.get("collection") == "core.get_jobs":
                fields = p.get("fields") or {}
                if self.call_id in (fields.get("message_ids") or []):
                    self.job_id = fields.get("id")
                    prog = fields.get("progress") or {}
                    key = (p.get("msg"), fields.get("state"), prog.get("percent"))
                    if key != self._progress_key:  # dedupe consecutive repeats
                        self._progress_key = key
                        note_progress(fields.get("id"), p.get("msg"),
                                      fields.get("state"), prog.get("percent"),
                                      prog.get("description"))
            return None
        if resp.get("id") == self.call_id:
            return resp
        return None  # unrelated notification

    # websocket-client (sync) driver
    def _rpc_sync(self, ws, method, params, deadline):
        import socket
        self.next_id += 1
        self.call_id = self.next_id
        self._progress_key = None
        ws.send(json.dumps({"jsonrpc": "2.0", "id": self.call_id,
                            "method": method, "params": params}))
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no response within {self.op_timeout}s")
            ws.settimeout(min(remaining, 30))
            try:
                raw = ws.recv()
            except socket.timeout:
                continue
            resp = self._handle(raw)
            if resp is not None:
                return resp

    # websockets (asyncio) driver
    async def _rpc_async(self, ws, method, params, deadline):
        self.next_id += 1
        self.call_id = self.next_id
        self._progress_key = None
        await ws.send(json.dumps({"jsonrpc": "2.0", "id": self.call_id,
                                  "method": method, "params": params}))
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no response within {self.op_timeout}s")
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
            resp = self._handle(raw)
            if resp is not None:
                return resp

    def run(self):
        try:
            import websockets  # noqa: F401
        except ImportError:
            self._run_sync()
        else:
            asyncio.run(self._run_async())

    async def _run_async(self):
        ws = await asyncio.wait_for(self._connect(), timeout=self.op_timeout)
        try:
            deadline = time.monotonic() + self.op_timeout
            await asyncio.wait_for(
                self._rpc_async(ws, "auth.login_with_api_key", [API_KEY], deadline),
                timeout=self.op_timeout)
            if MODE == "call":
                method, params = METHOD, PARAMS
            else:
                method, params = "core.get_jobs", [[["id", "=", JOB_ID]]]
            self.response = await asyncio.wait_for(
                self._rpc_async(ws, method, params, deadline),
                timeout=self.op_timeout)
        finally:
            await ws.close()

    def _run_sync(self):
        ws = self._connect()
        try:
            deadline = time.monotonic() + self.op_timeout
            self._rpc_sync(ws, "auth.login_with_api_key", [API_KEY], deadline)
            if MODE == "call":
                method, params = METHOD, PARAMS
            else:
                method, params = "core.get_jobs", [[["id", "=", JOB_ID]]]
            self.response = self._rpc_sync(ws, method, params, deadline)
        finally:
            try:
                ws.close()
            except Exception:
                pass


def main():
    client = Client(TIMEOUT)
    try:
        client.run()
    except TimeoutError as e:
        INFO["error_text"] = str(e)
        INFO["timeout"] = True
        dump_info()
        print(f"ERROR timeout: {e}", file=sys.stderr)
        sys.exit(EXIT_TIMEOUT)
    except Exception as e:
        INFO["error_text"] = f"connection failed: {e}"
        dump_info()
        print(f"ERROR transport: {e}", file=sys.stderr)
        sys.exit(EXIT_TRANSPORT)

    resp = client.response
    if resp.get("error") is not None:
        INFO.update(flatten_error(resp["error"]))
        INFO["job_id"] = client.job_id
        dump_info()
        print(f"ERROR rpc: {INFO['error_text']}", file=sys.stderr)
        sys.exit(EXIT_RPC)

    if MODE == "job" and isinstance(resp.get("result"), list) and resp["result"]:
        rec = resp["result"][0]
        INFO.update({"job_id": rec.get("id"), "state": rec.get("state"),
                     "logs_excerpt": rec.get("logs_excerpt"),
                     "logs_path": rec.get("logs_path")})
    INFO.setdefault("job_id", client.job_id)
    dump_info()
    print(json.dumps(resp.get("result")))


if __name__ == "__main__":
    main()
PYEOF
}

# ── ws_call METHOD PARAMS_JSON [TIMEOUT] ─────────────────────────────────────
# Runs one JSON-RPC call over WebSocket. Prints the result JSON to stdout;
# helper stderr (progress + INFO line) passes through to the terminal.
# The last INFO line is kept in _LAST_INFO for error classification.
ws_call() {
    local method="$1"
    local params_json="$2"
    local timeout="${3:-$CALL_TIMEOUT}"

    local tmp_err rc=0
    tmp_err=$(mktemp)
    WS_URI="$WS_URI" \
    WS_API_KEY="$TRUENAS_API_KEY" \
    WS_VERIFY_SSL="$VERIFY_SSL" \
    python3 "$WS_CLIENT" call "$method" "$params_json" "$timeout" \
        2> >(sed -E '/^INFO /d; s/^PROGRESS /  ↳ /' | tee "$tmp_err" >&2) || rc=$?
    _LAST_INFO=$(grep '^INFO ' "$tmp_err" | tail -n 1 | cut -c6- 2>/dev/null || true)
    rm -f "$tmp_err"
    return $rc
}

# ws_job_info JOB_ID
# Fetches a job record via core.get_jobs; prints the record JSON to stdout.
ws_job_info() {
    local job_id="$1"
    WS_URI="$WS_URI" \
    WS_API_KEY="$TRUENAS_API_KEY" \
    WS_VERIFY_SSL="$VERIFY_SSL" \
    python3 "$WS_CLIENT" job "$job_id" "$CALL_TIMEOUT"
}

# last_info FIELD [DEFAULT]
# Reads a field from the structured info emitted by the last ws_call.
last_info() {
    local field="$1" default="${2:-}"
    [[ -n "${_LAST_INFO:-}" ]] || { printf '%s' "$default"; return; }
    printf '%s' "$_LAST_INFO" | jq -r --arg f "$field" --arg d "$default" \
        '.[$f] // $d' 2>/dev/null || printf '%s' "$default"
}

# ── Failure log display ───────────────────────────────────────────────────────
# show_job_logs JOB_ID
# Prints the middleware-provided log excerpt (logs_excerpt) for a failed job,
# or an SSH/UI fallback hint when TrueNAS did not capture one.
show_job_logs() {
    local job_id="$1"
    local excerpt
    excerpt=$(ws_job_info "$job_id" 2>/dev/null \
        | jq -r '.[0].logs_excerpt // ""' 2>/dev/null || true)

    if [[ -n "$excerpt" ]]; then
        printf '%b  ── Job %s log (last lines) ──%b\n' "$YELLOW" "$job_id" "$NC" >&2
        printf '%s\n' "$excerpt" | tail -n 40 | sed 's/^/  │ /' >&2
        printf '%b  ────────────────────────────────────────────%b\n' \
            "$YELLOW" "$NC" >&2
    else
        printf '%b  Tip:%b check the job log in the TrueNAS UI (Jobs) or run:\n' \
            "$YELLOW" "$NC" >&2
        printf '       ssh root@%s "tail -50 /var/log/app_lifecycle.log"\n' \
            "$(printf '%s' "$TRUENAS_HOST" | sed -E 's|^[a-z]+://||')" >&2
    fi
}

# ── Core logic ────────────────────────────────────────────────────────────────
# NOTE: get_upgradeable_apps is called via $() so ALL stdout is captured by the
# caller. Log calls go to stderr (>&2) so they reach the terminal without
# polluting the captured JSON output.
get_upgradeable_apps() {
    local all_apps
    all_apps=$(ws_call app.query '[]') || die "Failed to retrieve app list."

    local total
    total=$(printf '%s' "$all_apps" | jq 'length')
    log_info "Found ${total} installed app(s)." >&2   # >&2 keeps log off captured stdout

    # Filter to only apps that have upgrade_available == true
    printf '%s' "$all_apps" | jq '[.[] | select(.upgrade_available == true)]'
}

print_update_table() {
    local upgradeable="$1"
    local count
    count=$(printf '%s' "$upgradeable" | jq 'length')
    log_header "Apps with available updates (${count})"

    if command -v column &>/dev/null; then
        printf '%s' "$upgradeable" | jq -r \
            '.[] | [.name, (.human_version // .version // "?"), "→", (.latest_version // "latest")] | @tsv' \
            | column -t -s $'\t' | sed 's/^/  /'
    else
        printf '%s' "$upgradeable" | jq -r \
            '.[] | "  \(.name)\t\(.human_version // .version // "?") → \(.latest_version // "latest")"'
    fi
}

# ── Start a stopped app before upgrading ─────────────────────────────────────
# ensure_app_running APP_NAME
# Issues app.start (a JSON-RPC job) and waits for completion. Always returns 0
# (non-fatal) so that a failed start does not prevent the upgrade attempt.
ensure_app_running() {
    local app_name="$1"
    log_info "  ${app_name} is stopped — starting before upgrade..."

    if ! ws_call app.start "[\"${app_name}\"]" "$JOB_TIMEOUT" >/dev/null; then
        log_warn "  Could not start ${app_name} — proceeding anyway."
        return 0
    fi
    log_ok "  ${app_name} started."
    return 0
}

upgrade_app() {
    local app_name="$1"

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "  [DRY RUN] Would upgrade: ${app_name}"
        return 0
    fi

    log_info "  Starting upgrade for ${app_name}..."
    log_info "  Using: app.upgrade(\"${app_name}\")"

    local result
    if ! result=$(ws_call app.upgrade "[\"${app_name}\"]" "$JOB_TIMEOUT"); then
        local err_text job_id
        err_text=$(last_info error_text "unknown error")
        job_id=$(last_info job_id "")

        log_error "  ${app_name}: app.upgrade failed — ${err_text}"

        # Show the middleware-captured log excerpt when available
        [[ -n "$job_id" && "$job_id" != "null" ]] && show_job_logs "$job_id"

        # Non-retriable validation errors (invalid config values that must be
        # corrected in the TrueNAS UI before upgrading).
        if [[ "$err_text" == *"[EINVAL]"* ]]; then
            log_warn "  ${app_name}: this is a configuration error — retrying will not help."
            log_warn "  Fix it in the TrueNAS UI (Apps → ${app_name} → Edit) then re-run."
            return 2   # caller: skip retries for this app
        fi

        # App must be running to upgrade
        if [[ "$err_text" == *"stopped state"* ]]; then
            log_warn "  ${app_name}: app must be running to upgrade — will start and retry."
            return 3   # caller: start app then retry
        fi

        return 1
    fi

    log_ok "  ${app_name}: upgrade complete."
    return 0
}

# ── Results report (stdout only) ─────────────────────────────────────────────
# print_results SUCCEEDED_APPS_ARRAY FAILED_APPS_ARRAY
# All output goes to stdout so it can be captured or piped.
print_results() {
    local -n _succeeded="$1"
    local -n _failed="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    printf '\n'
    printf '=%.0s' {1..60}; printf '\n'
    printf 'TRUENAS APP UPDATE RESULTS — %s\n' "$ts"
    printf '=%.0s' {1..60}; printf '\n'
    printf 'Succeeded : %d\n' "${#_succeeded[@]}"
    if [[ ${#_succeeded[@]} -gt 0 ]]; then
        printf '  + %s\n' "${_succeeded[@]}"
    fi
    printf 'Failed    : %d\n' "${#_failed[@]}"
    if [[ ${#_failed[@]} -gt 0 ]]; then
        printf '  - %s\n' "${_failed[@]}"
    fi
    printf '=%.0s' {1..60}; printf '\n'
}

# ── API probe (debugging) ─────────────────────────────────────────────────────
# Lists all app.* methods exposed by the JSON-RPC API so the caller can
# identify the correct method for their TrueNAS version.
probe_api() {
    log_header "Probing TrueNAS JSON-RPC API for app methods …"

    local methods
    methods=$(ws_call core.get_methods '[]') || {
        log_error "Could not retrieve method list."
        return 1
    }

    if command -v column &>/dev/null; then
        printf '%s' "$methods" | jq -r 'keys[] | select(startswith("app"))' | column -c 80
    else
        printf '%s' "$methods" | jq -r 'keys[] | select(startswith("app"))' | sed 's/^/  /'
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    log_header "TrueNAS SCALE App Updater (JSON-RPC 2.0 over WebSocket)"
    [[ "$DRY_RUN" == true ]] && log_warn "Dry-run mode active — no changes will be applied."

    check_dependencies
    validate_config
    build_ws_uri
    write_ws_client

    # Connection test
    log_info "Connecting to ${WS_URI} …"
    local sys_info version
    sys_info=$(ws_call system.info '[]') || die "Cannot reach TrueNAS API."
    version=$(printf '%s' "$sys_info" | jq -r '.version // "unknown"')
    log_ok "Connected — TrueNAS ${version}"

    # Probe mode: print API methods and exit
    if [[ "$PROBE_API" == true ]]; then
        probe_api
        exit 0
    fi

    # ── Helper: apply TARGET_APPS filter to an upgradeable JSON list ────────────
    filter_targets() {
        local json="$1"
        if [[ ${#TARGET_APPS[@]} -eq 0 ]]; then
            printf '%s' "$json"
            return
        fi
        local f
        f=$(printf '%s\n' "${TARGET_APPS[@]}" | jq -R . | jq -sc .)
        printf '%s' "$json" | jq --argjson f "$f" \
            '[.[] | select(.name as $n | $f | index($n))]'
    }

    # ── Initial update check ─────────────────────────────────────────────────
    log_header "Checking for app updates …"
    local upgradeable upgradeable_count
    upgradeable=$(get_upgradeable_apps)
    upgradeable=$(filter_targets "$upgradeable")
    upgradeable_count=$(printf '%s' "$upgradeable" | jq 'length')

    if [[ $upgradeable_count -eq 0 ]]; then
        log_ok "All apps are up to date."
        exit 0
    fi

    # Warn about any requested target apps not in the upgradeable list
    if [[ ${#TARGET_APPS[@]} -gt 0 ]]; then
        for app in "${TARGET_APPS[@]}"; do
            local found
            found=$(printf '%s' "$upgradeable" | jq -r --arg a "$app" \
                'map(select(.name == $a)) | length')
            [[ "$found" -eq 0 ]] && \
                log_warn "  '${app}' has no update available (up to date or not installed)."
        done
        if [[ $upgradeable_count -eq 0 ]]; then
            log_ok "None of the specified apps have updates available."
            exit 0
        fi
    fi

    print_update_table "$upgradeable"
    echo

    # Confirm once before any upgrades begin
    if [[ "$AUTO_CONFIRM" != true && "$DRY_RUN" != true ]]; then
        read -rp "Apply ${upgradeable_count} update(s)? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }
    fi

    # ── Iterative upgrade loop ────────────────────────────────────────────────
    # After each pass, re-check for any updates that became available (e.g. a
    # dependency that unlocked a newer version). Stop when TrueNAS reports
    # nothing left, when a full pass produces zero successes, or after
    # MAX_ROUNDS passes (safety guard against infinite loops).
    local MAX_ROUNDS=10
    local round=0
    local total_success=0 total_failed=0
    local all_succeeded=() all_failed=()

    while true; do
        (( round++ )) || true
        log_header "Applying updates — pass ${round} of ${MAX_ROUNDS} (${upgradeable_count} app(s)) …"

        local n_success=0 n_failed=0
        local succeeded_apps=() failed_apps=()

        while IFS=$'\t' read -r app_name app_state; do
            # Start stopped apps before attempting an upgrade
            if [[ "$app_state" == "STOPPED" ]]; then
                ensure_app_running "$app_name"
            fi

            # Retry loop for transient job failures.
            # Exit code 0 = success, 1 = retriable failure,
            #              2 = fatal/non-retriable, 3 = start app then retry.
            local attempt=1 app_ok=false upgrade_rc
            while [[ $attempt -le $((RETRIES + 1)) ]]; do
                if [[ $attempt -gt 1 ]]; then
                    log_warn "  ${app_name}: retry ${attempt} of $((RETRIES + 1)) — waiting ${RETRY_DELAY}s..."
                    sleep "$RETRY_DELAY"
                fi
                upgrade_rc=0
                upgrade_app "$app_name" || upgrade_rc=$?
                if [[ $upgrade_rc -eq 0 ]]; then
                    app_ok=true
                    break
                elif [[ $upgrade_rc -eq 2 ]]; then
                    # Fatal configuration error — retrying will never succeed
                    break
                elif [[ $upgrade_rc -eq 3 ]]; then
                    # App is stopped — start it now so the next retry can proceed
                    ensure_app_running "$app_name"
                fi
                # rc=1 (retriable) or rc=3 (started, now retry): fall through
                (( attempt++ )) || true
            done

            if $app_ok; then
                (( n_success++ )) || true
                succeeded_apps+=("$app_name")
            else
                (( n_failed++ )) || true
                failed_apps+=("$app_name")
            fi
        done < <(printf '%s' "$upgradeable" \
            | jq -r '.[] | [.name, (.state // "UNKNOWN")] | @tsv')

        total_success=$((total_success + n_success))
        total_failed=$((total_failed + n_failed))
        [[ ${#succeeded_apps[@]} -gt 0 ]] && all_succeeded+=("${succeeded_apps[@]}")
        [[ ${#failed_apps[@]} -gt 0 ]]    && all_failed+=("${failed_apps[@]}")

        # Stop conditions
        if [[ "$DRY_RUN" == true ]]; then
            log_warn "Dry-run: skipping further passes."
            break
        fi
        if [[ $n_success -eq 0 ]]; then
            log_info "No apps upgraded this pass — stopping."
            break
        fi
        if [[ $round -ge $MAX_ROUNDS ]]; then
            log_warn "Reached maximum of ${MAX_ROUNDS} passes — stopping."
            break
        fi

        # Re-check TrueNAS for any newly available updates
        log_info "Re-checking for remaining updates …"
        upgradeable=$(get_upgradeable_apps)
        upgradeable=$(filter_targets "$upgradeable")
        upgradeable_count=$(printf '%s' "$upgradeable" | jq 'length')

        if [[ $upgradeable_count -eq 0 ]]; then
            log_ok "No more updates available."
            break
        fi

        log_info "Found ${upgradeable_count} more update(s):"
        print_update_table "$upgradeable"
        echo
    done

    # ── Final summary ─────────────────────────────────────────────────────────
    log_header "Final Summary (${round} pass(es))"
    log_ok "Succeeded: ${total_success}"
    if [[ $total_failed -gt 0 ]]; then
        log_error "Failed:    ${total_failed} (${all_failed[*]})"
    fi
    [[ "$DRY_RUN" == true ]] && log_warn "No changes were applied (dry-run mode)."

    [[ "$PRINT_RESULTS" == true ]] && print_results all_succeeded all_failed

    [[ $total_failed -eq 0 ]]
}

main "$@"
