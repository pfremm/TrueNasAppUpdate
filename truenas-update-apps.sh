#!/usr/bin/env bash
# ==============================================================================
# truenas-update-apps.sh
# Check for and apply app updates via the TrueNAS SCALE 25.04 REST API.
#
# Usage:
#   ./truenas-update-apps.sh [options] [app_name ...]
#
# Options:
#   -h, --host HOST       TrueNAS hostname or IP (overrides TRUENAS_HOST)
#   -k, --api-key KEY     API key (overrides TRUENAS_API_KEY)
#   -d, --dry-run         List updates but do not apply them
#   -y, --yes             Skip confirmation prompt
#   -n, --no-confirm      Skip confirmation and print a results summary to stdout
#       --probe-api       Print available /app/* REST endpoints and exit (debugging)
#       --no-verify-ssl   Disable SSL certificate verification
#       --timeout SECS    curl timeout per request (default: 30)
#       --job-timeout SECS Max seconds to wait for an upgrade job (default: 600)
#       --retries N       Retry a failed upgrade N times before giving up (default: 1)
#       --retry-delay SECS Seconds to wait between retries (default: 15)
#   [app_name ...]        Only update the named apps (default: all updatable apps)
#
# Environment variables (used when flags are omitted):
#   TRUENAS_HOST          e.g. https://192.168.1.100
#   TRUENAS_API_KEY       API key generated in TrueNAS UI → API Keys
#
# Exit codes:
#   0  All targeted updates succeeded (or nothing to update)
#   1  One or more upgrades failed, or a fatal error occurred
# ==============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
TRUENAS_HOST="${TRUENAS_HOST:-}"
TRUENAS_API_KEY="${TRUENAS_API_KEY:-}"
DRY_RUN=false
AUTO_CONFIRM=false
PRINT_RESULTS=false
PROBE_API=false
VERIFY_SSL=true
CURL_TIMEOUT=30
JOB_TIMEOUT=600
RETRIES=3        # number of retry attempts after a failed upgrade job
RETRY_DELAY=15   # seconds to wait between retries
TARGET_APPS=()   # empty = all upgradeable apps

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
            --timeout)        CURL_TIMEOUT="$2";    shift 2 ;;
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
    for cmd in curl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
}

validate_config() {
    [[ -n "$TRUENAS_HOST"    ]] || die "TrueNAS host not set. Use --host or export TRUENAS_HOST."
    [[ -n "$TRUENAS_API_KEY" ]] || die "API key not set. Use --api-key or export TRUENAS_API_KEY."
    TRUENAS_HOST="${TRUENAS_HOST%/}"   # strip any trailing slash
}

# ── API helper ────────────────────────────────────────────────────────────────
# api_call METHOD /endpoint [json_body]
# Prints the response body to stdout; returns non-zero on HTTP error.
# Uses a temp file for the body so curl stderr never contaminates the JSON.
api_call() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"
    local url="${TRUENAS_HOST}/api/v2.0${endpoint}"

    local tmp_body
    tmp_body=$(mktemp) || die "Failed to create temp file."

    local curl_opts=(
        --silent
        --show-error
        --max-time "$CURL_TIMEOUT"
        --header "Authorization: Bearer ${TRUENAS_API_KEY}"
        --header "Content-Type: application/json"
        --request "$method"
        --output  "$tmp_body"       # body goes to file, not stdout
        --write-out '%{http_code}'  # only the status code goes to stdout
    )
    [[ "$VERIFY_SSL" == false ]] && curl_opts+=(--insecure)
    [[ -n "$body" ]] && curl_opts+=(--data "$body")

    local http_code
    http_code=$(curl "${curl_opts[@]}" "$url") || {
        rm -f "$tmp_body"
        die "curl failed for ${method} ${endpoint}"
    }

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log_error "HTTP ${http_code} for ${method} ${endpoint}"
        log_error "Response: $(cat "$tmp_body")"
        rm -f "$tmp_body"
        return 1
    fi

    cat "$tmp_body"
    rm -f "$tmp_body"
}

# ── Remote log fetcher ────────────────────────────────────────────────────────
# fetch_log_tail REMOTE_PATH [LINES]
# Tries to read the tail of a file on the TrueNAS host via the filesystem API.
# Prints the lines to stderr so they appear inline with other log output.
# Silently does nothing if the API doesn't support it.
fetch_log_tail() {
    local remote_path="$1"
    local lines="${2:-40}"

    # TrueNAS exposes filesystem reads via a POST that returns the raw file.
    # We tail it locally after fetching.
    local tmp_log
    tmp_log=$(mktemp)

    local curl_opts=(
        --silent --max-time "$CURL_TIMEOUT"
        --header "Authorization: Bearer ${TRUENAS_API_KEY}"
        --header "Content-Type: application/json"
        --request GET
        --output "$tmp_log"
        --write-out '%{http_code}'
    )
    [[ "$VERIFY_SSL" == false ]] && curl_opts+=(--insecure)

    local http_code
    # Endpoint: GET /api/v2.0/filesystem/get?path=<path>
    http_code=$(curl "${curl_opts[@]}" \
        "${TRUENAS_HOST}/api/v2.0/filesystem/get?path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$remote_path" 2>/dev/null || printf '%s' "$remote_path")")

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 && -s "$tmp_log" ]]; then
        printf '%b  ── Last %d lines of %s ──%b\n' "$YELLOW" "$lines" "$remote_path" "$NC" >&2
        tail -n "$lines" "$tmp_log" | sed 's/^/  │ /' >&2
        printf '%b  ────────────────────────────────────────────%b\n' "$YELLOW" "$NC" >&2
    else
        # API fetch failed — show an SSH fallback hint instead
        printf '%b  Tip:%b To view the full log, run:\n' "$YELLOW" "$NC" >&2
        printf '       ssh root@%s "tail -50 %s"\n' \
            "$(printf '%s' "$TRUENAS_HOST" | sed 's|https\?://||')" \
            "$remote_path" >&2
    fi

    rm -f "$tmp_log"
}

# ── Wait for a TrueNAS background job ────────────────────────────────────────
# wait_for_job JOB_ID APP_NAME
wait_for_job() {
    local job_id="$1"
    local app_name="$2"
    local elapsed=0
    local poll_interval=5
    local last_percent=-1

    while [[ $elapsed -lt $JOB_TIMEOUT ]]; do
        local job state percent err

        job=$(api_call GET "/core/get_jobs?id=${job_id}" 2>/dev/null) || {
            sleep "$poll_interval"
            elapsed=$((elapsed + poll_interval))
            continue
        }

        state=$(printf '%s' "$job"   | jq -r '.[0].state   // "UNKNOWN"')
        percent=$(printf '%s' "$job" | jq -r '.[0].progress.percent // 0' | cut -d'.' -f1)

        case "$state" in
            SUCCESS)
                printf '\r\033[K'   # clear progress line
                log_ok "  ${app_name}: upgrade complete."
                return 0
                ;;
            FAILED|ABORTED)
                printf '\r\033[K'
                err=$(printf '%s' "$job" | jq -r '.[0].error // "unknown error"')
                log_error "  ${app_name}: upgrade ${state,,} — ${err}"

                # If TrueNAS mentions a log file path, fetch and display it
                local log_path
                log_path=$(printf '%s' "$err" \
                    | grep -oE '/[a-zA-Z0-9_./-]+\.log' | head -1)
                [[ -n "$log_path" ]] && fetch_log_tail "$log_path"

                # App is stopped — caller should start it and retry.
                if [[ "$err" == *"stopped state"* ]]; then
                    log_warn "  ${app_name}: app must be running to upgrade — will start and retry."
                    return 3   # caller: start app then retry
                fi

                # Detect non-retriable validation errors (e.g. invalid config values
                # that must be corrected in the TrueNAS UI before upgrading).
                if [[ "$err" == *"[EINVAL]"* ]]; then
                    log_warn "  ${app_name}: this is a configuration error — retrying will not help."
                    log_warn "  Fix it in the TrueNAS UI (Apps → ${app_name} → Edit) then re-run."
                    return 2   # caller: skip retries for this app
                fi

                return 1
                ;;
            RUNNING|WAITING)
                if [[ "$percent" != "$last_percent" ]]; then
                    printf '\r%b[INFO]%b  %s — %s%% ' "$BLUE" "$NC" "$app_name" "$percent"
                    last_percent="$percent"
                fi
                ;;
        esac

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    printf '\r\033[K'
    log_error "  ${app_name}: timed out after ${JOB_TIMEOUT}s waiting for job ${job_id}."
    return 1
}

# ── Core logic ────────────────────────────────────────────────────────────────
# NOTE: this function is called via $() so ALL stdout is captured by the caller.
# Log calls must go to stderr (>&2) so they reach the terminal without polluting
# the captured JSON output.
get_upgradeable_apps() {
    local all_apps
    all_apps=$(api_call GET "/app") || die "Failed to retrieve app list."

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

    printf '%s' "$upgradeable" | jq -r \
        '.[] | [.name, (.version // "?"), "→", (.human_latest_version // "latest")] | @tsv' \
        | column -t -s $'\t' | sed 's/^/  /'
}

# ── Start a stopped app before upgrading ─────────────────────────────────────
# ensure_app_running APP_NAME
# Issues a start job and waits for completion. Always returns 0 (non-fatal)
# so that a failed start does not prevent the upgrade attempt.
ensure_app_running() {
    local app_name="$1"
    log_info "  ${app_name} is stopped — starting before upgrade..."

    local tmp_body http_code
    tmp_body=$(mktemp) || { log_warn "  Could not create temp file; skipping start."; return 0; }

    local curl_opts=(
        --silent --show-error --max-time "$CURL_TIMEOUT"
        --header "Authorization: Bearer ${TRUENAS_API_KEY}"
        --header "Content-Type: application/json"
        --request POST --data '{}'
        --output "$tmp_body" --write-out '%{http_code}'
    )
    [[ "$VERIFY_SSL" == false ]] && curl_opts+=(--insecure)

    http_code=$(curl "${curl_opts[@]}" "${TRUENAS_HOST}/api/v2.0/app/${app_name}/start")

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log_warn "  Could not start ${app_name} (HTTP ${http_code}) — proceeding anyway."
        rm -f "$tmp_body"
        return 0
    fi

    local job_id
    job_id=$(jq -r '.' < "$tmp_body")
    rm -f "$tmp_body"

    if [[ -z "$job_id" || "$job_id" == "null" ]]; then
        log_warn "  No start job ID returned for ${app_name} — proceeding anyway."
        return 0
    fi

    # Wait for the start job; warn but don't abort if it fails
    wait_for_job "$job_id" "${app_name} (start)" \
        || log_warn "  Start job did not complete cleanly for ${app_name} — proceeding anyway."
    return 0
}

# _try_upgrade_endpoint CURL_BASE_ARRAY_NAME URL BODY
# Fires a single POST and writes the HTTP code to stdout.
# The response body is written to the file named in $TMP_BODY (caller-set global).
_try_upgrade_endpoint() {
    local -n _base="$1"
    local url="$2"
    local body="$3"
    truncate -s 0 "$TMP_BODY"
    curl "${_base[@]}" \
        --request POST --data "$body" \
        --output "$TMP_BODY" --write-out '%{http_code}' \
        "$url"
}

upgrade_app() {
    local app_name="$1"

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "  [DRY RUN] Would upgrade: ${app_name}"
        return 0
    fi

    log_info "  Starting upgrade for ${app_name}..."

    local curl_base=(
        --silent --show-error --max-time "$CURL_TIMEOUT"
        --header "Authorization: Bearer ${TRUENAS_API_KEY}"
        --header "Content-Type: application/json"
    )
    [[ "$VERIFY_SSL" == false ]] && curl_base+=(--insecure)

    # TMP_BODY is shared by _try_upgrade_endpoint (must be exported to subshells).
    TMP_BODY=$(mktemp) || die "Failed to create temp file."
    local http_code used_method
    local base="${TRUENAS_HOST}/api/v2.0"

    # ── Pattern A: name in URL — catalog version upgrade ──────────────────────
    http_code=$(_try_upgrade_endpoint curl_base \
        "${base}/app/${app_name}/upgrade" '{}')
    used_method="POST /app/${app_name}/upgrade"

    # ── Pattern B: name in URL — Docker image pull + redeploy ─────────────────
    if [[ "$http_code" -eq 404 ]]; then
        log_info "  Trying image pull for ${app_name}..."
        http_code=$(_try_upgrade_endpoint curl_base \
            "${base}/app/${app_name}/pull_images" '{"redeploy": true}')
        used_method="POST /app/${app_name}/pull_images"
    fi

    # ── Pattern C: name in body — some 25.04 builds map methods this way ──────
    if [[ "$http_code" -eq 404 ]]; then
        log_info "  Trying body-based upgrade for ${app_name}..."
        http_code=$(_try_upgrade_endpoint curl_base \
            "${base}/app/upgrade" "{\"app_name\": \"${app_name}\"}")
        used_method="POST /app/upgrade {app_name}"
    fi

    # ── Pattern D: name in body — image pull variant ───────────────────────────
    if [[ "$http_code" -eq 404 ]]; then
        log_info "  Trying body-based image pull for ${app_name}..."
        http_code=$(_try_upgrade_endpoint curl_base \
            "${base}/app/pull_images" \
            "{\"app_name\": \"${app_name}\", \"options\": {\"redeploy\": true}}")
        used_method="POST /app/pull_images {app_name}"
    fi

    if [[ "$http_code" -eq 404 ]]; then
        log_error "  All upgrade patterns returned 404 for ${app_name}."
        log_warn   "  Run with --probe-api to discover the correct endpoint on your TrueNAS version."
        rm -f "$TMP_BODY"
        return 1
    fi

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log_error "  ${app_name}: ${used_method} failed (HTTP ${http_code})"
        log_error "  Response: $(cat "$TMP_BODY")"
        rm -f "$TMP_BODY"
        return 1
    fi

    log_info "  Using: ${used_method}"

    local job_id
    job_id=$(jq -r '.' < "$TMP_BODY")
    rm -f "$TMP_BODY"

    if [[ -z "$job_id" || "$job_id" == "null" ]]; then
        log_error "  No job ID returned for ${app_name}."
        return 1
    fi

    wait_for_job "$job_id" "$app_name"
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
# Fetches the OpenAPI schema and prints all /app/* paths so the caller can
# identify the correct upgrade endpoint for their TrueNAS version.
probe_api() {
    log_header "Probing TrueNAS REST API schema for /app endpoints …"

    local schema
    schema=$(api_call GET "/../docs/restful-api.json" 2>/dev/null) \
        || schema=$(api_call GET "/_schema" 2>/dev/null) \
        || { log_error "Could not retrieve OpenAPI schema."; return 1; }

    local paths
    paths=$(printf '%s' "$schema" | jq -r '
        .paths
        | to_entries[]
        | select(.key | startswith("/app"))
        | "\(.value | keys | map(ascii_upcase) | join(","))\t\(.key)"
    ' 2>/dev/null | sort -k2 | column -t -s $'\t')

    if [[ -z "$paths" ]]; then
        log_warn "Schema found but no /app paths returned — trying raw path list."
        printf '%s' "$schema" | jq -r 'keys[]' 2>/dev/null | grep -i app || true
    else
        printf '%s\n' "$paths"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    log_header "TrueNAS SCALE App Updater"
    [[ "$DRY_RUN" == true ]] && log_warn "Dry-run mode active — no changes will be applied."

    check_dependencies
    validate_config

    # Connection test
    log_info "Connecting to ${TRUENAS_HOST} …"
    local sys_info version
    sys_info=$(api_call GET "/system/info") || die "Cannot reach TrueNAS API."
    version=$(printf '%s' "$sys_info" | jq -r '.version // "unknown"')
    log_ok "Connected — TrueNAS ${version}"

    # Probe mode: print API schema and exit
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
