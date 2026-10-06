#!/usr/bin/env bash
# quota-push.sh: collect one quota-axi report, validate it, and push it to
# agentboard. Meant to run every ~5 minutes from launchd, a systemd timer, or
# cron. Guide: docs/setup/quota-producer.md
#
#   scripts/quota-push.sh            collect, validate, push
#   scripts/quota-push.sh --dry-run  collect and validate only
#
# Configuration comes from the environment, optionally loaded from
# $AGENTBOARD_ENV_FILE (default ~/.config/agentboard/quota-push.env);
# variables already set in the environment take precedence:
#
#   AGENTBOARD_URL       API base URL (HTTPS, or http://localhost / 127.0.0.1)
#   AGENT_ID             stable ID of the agent that pushes quota
#   AGENTBOARD_HARNESS   harness stamped on the push (e.g. shell, codex)
#   AGENTBOARD_MODEL     model or actor stamped on the push
#   AGENTBOARD_CA_FILE   optional extra CA bundle for a private HTTPS CA
#   QUOTA_AXI            quota-axi command (default: quota-axi on PATH)
#   AGENTBOARD_BIN       agentboard command (default: agentboard on PATH)
#   QUOTA_MAX_AGE        quota-axi --max-age (default 90s)
#   QUOTA_COLLECT_TIMEOUT  seconds allowed for quota-axi (default 90)
#   QUOTA_PUSH_TIMEOUT     seconds allowed for the push (default 60)
#   QUOTA_PUSH_STATE_DIR   lock and scratch directory
#                          (default ${XDG_STATE_HOME:-~/.local/state}/agentboard)
#
# Each run prints exactly one line: "<UTC time> OK ..." on stdout, or
# "<UTC time> FAIL|SKIP|RATE_LIMITED ..." on stderr. Report contents, account
# details and tool error output are never printed.
#
# Exit codes: 0 pushed (or validated with --dry-run), 1 failure, 2 usage,
# 75 skipped or rate limited (try again on the next run).
set -euo pipefail

dry_run=0
case "${1:-}" in
  --dry-run) dry_run=1 ;;
  "") ;;
  -h | --help)
    sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "usage: $0 [--dry-run]" >&2
    exit 2
    ;;
esac

env_file="${AGENTBOARD_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/agentboard/quota-push.env}"
if [[ -f "$env_file" ]]; then
  # Variables already set in the environment win over the file.
  saved=""
  for var in AGENTBOARD_URL AGENT_ID AGENTBOARD_HARNESS AGENTBOARD_MODEL \
    AGENTBOARD_CA_FILE QUOTA_AXI AGENTBOARD_BIN QUOTA_MAX_AGE \
    QUOTA_COLLECT_TIMEOUT QUOTA_PUSH_TIMEOUT QUOTA_PUSH_STATE_DIR; do
    if [[ -n "${!var:-}" ]]; then
      saved="$saved$(printf '%s=%q' "$var" "${!var}")"$'\n'
    fi
  done
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  eval "$saved"
  set +a
fi

quota_axi="${QUOTA_AXI:-quota-axi}"
agentboard="${AGENTBOARD_BIN:-agentboard}"
max_age="${QUOTA_MAX_AGE:-90s}"
collect_timeout="${QUOTA_COLLECT_TIMEOUT:-90}"
push_timeout="${QUOTA_PUSH_TIMEOUT:-60}"
state_dir="${QUOTA_PUSH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agentboard}"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
finish() { # finish <exit code> <status> <message>
  if [[ "$1" -eq 0 ]]; then
    echo "$(stamp) $2 $3"
  else
    echo "$(stamp) $2 $3" >&2
  fi
  exit "$1"
}

for var in AGENTBOARD_URL AGENT_ID AGENTBOARD_HARNESS AGENTBOARD_MODEL; do
  if [[ -z "${!var:-}" ]]; then
    finish 1 FAIL "$var is not set (environment or $env_file)"
  fi
done
export AGENTBOARD_URL AGENT_ID AGENTBOARD_HARNESS AGENTBOARD_MODEL
command -v "$quota_axi" >/dev/null 2>&1 || finish 1 FAIL "quota-axi not found on PATH ($PATH)"
command -v "$agentboard" >/dev/null 2>&1 || finish 1 FAIL "agentboard not found on PATH ($PATH)"
if command -v python3 >/dev/null 2>&1; then
  json_tool=python3
elif command -v jq >/dev/null 2>&1; then
  json_tool=jq
else
  finish 1 FAIL "python3 or jq is required to validate reports"
fi

umask 077
mkdir -p "$state_dir"

# One run at a time. A lock left by a crashed run is reclaimed.
lock="$state_dir/quota-push.lock"
if ! mkdir "$lock" 2>/dev/null; then
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    finish 75 SKIP "previous run still active (pid $holder)"
  fi
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || finish 75 SKIP "could not take the lock"
fi
echo "$$" >"$lock/pid"
work="$(mktemp -d "$state_dir/run.XXXXXX")"
trap 'rm -rf "$work" "$lock"' EXIT
trap 'exit 1' INT TERM

# run_bounded <seconds> <stdout file> <stderr file> <command...>
# Returns the command's status, or 124 if it ran out of time.
run_bounded() {
  local limit="$1" out="$2" err="$3"
  shift 3
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$limit" "$@" >"$out" 2>"$err"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 5 "$limit" "$@" >"$out" 2>"$err"
  else
    "$@" >"$out" 2>"$err" &
    local pid=$! status
    (
      sleep "$limit"
      kill -TERM "$pid" 2>/dev/null && sleep 5 && kill -KILL "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    local watchdog=$!
    status=0
    wait "$pid" || status=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    if [[ $status -eq 143 || $status -eq 137 ]]; then
      status=124
    fi
    return "$status"
  fi
}

report="$work/report.json"
status=0
run_bounded "$collect_timeout" "$report" "$work/collect.err" \
  "$quota_axi" --json --max-age "$max_age" --no-credential-refresh || status=$?
if [[ $status -eq 124 ]]; then
  finish 1 FAIL "quota-axi timed out after ${collect_timeout}s"
elif [[ $status -ne 0 ]]; then
  finish 1 FAIL "quota-axi exited $status (run it by hand to see why)"
fi
[[ -s "$report" ]] || finish 1 FAIL "quota-axi produced no output"

# Structural checks from docs/quota.md; prints a provider status summary.
validate_python() {
  python3 - "$1" <<'PY'
import json, sys
from collections import Counter
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit("report is not valid JSON")
version = data.get("schemaVersion") if isinstance(data, dict) else None
if version not in (5, 6):
    sys.exit("unsupported schemaVersion")
if not isinstance(data.get("generatedAt"), str) or not data["generatedAt"]:
    sys.exit("generatedAt is missing")
providers = data.get("providers")
if not isinstance(providers, list):
    sys.exit("providers is not a list")
statuses = Counter()
for row in providers:
    state = row.get("state") if isinstance(row, dict) else None
    if not isinstance(state, dict) or not row.get("provider"):
        sys.exit("provider row without provider or state")
    if not isinstance(state.get("status"), str) or not isinstance(state.get("stale"), bool):
        sys.exit("provider state needs status and boolean stale")
    if not isinstance(row.get("windows"), list):
        sys.exit("provider windows is not a list")
    if version == 6 and not row.get("accountKey"):
        sys.exit("schema 6 provider row without accountKey")
    statuses[state["status"]] += 1
summary = " ".join("{}={}".format(k, v) for k, v in sorted(statuses.items()))
print("providers={}{}".format(len(providers), " " + summary if summary else ""))
PY
}

validate_jq() {
  jq -er '
    def fail(m): error(m);
    if (type != "object") or ((.schemaVersion | IN(5, 6)) | not) then fail("unsupported schemaVersion")
    elif ((.generatedAt | type) != "string") or (.generatedAt == "") then fail("generatedAt is missing")
    elif (.providers | type) != "array" then fail("providers is not a list")
    elif any(.providers[];
        (type != "object")
        or ((.provider // "") == "")
        or ((.state | type) != "object")
        or ((.state.status | type) != "string")
        or ((.state.stale | type) != "boolean")
        or ((.windows | type) != "array")) then fail("invalid provider row")
    elif .schemaVersion == 6 and any(.providers[]; (.accountKey // "") == "") then fail("schema 6 provider row without accountKey")
    else
      "providers=\(.providers | length)"
      + ([.providers | group_by(.state.status)[] | " \(.[0].state.status)=\(length)"] | join(""))
    end' "$1" 2>/dev/null || {
    echo "report failed validation"
    return 1
  }
}

validate() {
  if [[ $json_tool == python3 ]]; then
    validate_python "$1"
  else
    validate_jq "$1"
  fi
}
if ! summary="$(validate "$report" 2>&1)"; then
  finish 1 FAIL "invalid quota-axi report: ${summary##*$'\n'}"
fi

if [[ $dry_run -eq 1 ]]; then
  finish 0 OK "dry run, report valid, $summary"
fi

# The CLI already waits and retries on 429 per Retry-After (within its
# request budget). If it still reports rate_limited, leave it to the next run.
pushed="$work/push.json"
status=0
run_bounded "$push_timeout" "$pushed" "$work/push.err" \
  "$agentboard" quota push --file="$report" --json || status=$?
if [[ $status -eq 124 ]]; then
  finish 1 FAIL "push timed out after ${push_timeout}s"
elif [[ $status -ne 0 ]]; then
  code="$(sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p' "$work/push.err" | head -n 1)"
  if [[ "$code" == rate_limited ]]; then
    finish 75 RATE_LIMITED "server still rate limiting after Retry-After; next run will try again"
  fi
  finish 1 FAIL "push exited $status (${code:-unknown error}); $summary"
fi

push_result() {
  if [[ $json_tool == python3 ]]; then
    python3 - "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
report = data.get("report") or {}
print("report={} idempotent={} generated_at={}".format(
    report.get("id"), str(data.get("idempotent")).lower(), report.get("generated_at")))
PY
  else
    jq -r '"report=\(.report.id) idempotent=\(.idempotent) generated_at=\(.report.generated_at)"' "$1"
  fi
}
result="$(push_result "$pushed" 2>/dev/null)" || result="report=unknown"
finish 0 OK "$result $summary"
