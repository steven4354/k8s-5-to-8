#!/usr/bin/env bash

# Generic optional OpenAI "suggest fixes" helper for shell scripts.
#
# Usage:
#   <build_prompt> | scripts/ai-suggest.sh [--title "AI Suggestions"]
#
# Opt-in behavior:
# - If OPENAI_API_KEY is set: will call OpenAI.
# - Else if interactive and AI_ASSIST_PROMPT=1: asks whether to enable, then prompts for key (hidden).
# - Otherwise: does nothing (no network).
#
# This script is intentionally safe to call from other scripts: failures do not fail the caller.

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: bash is required. Run: bash $0" >&2
  exit 1
fi

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_FILE="${REPO_ROOT}/.openai-api-key"

TITLE="AI Suggestions (optional)"

AI_ASSIST="${AI_ASSIST:-}"                 # set to 1 to force AI (requires key); 0 to disable prompts
AI_ASSIST_PROMPT="${AI_ASSIST_PROMPT:-1}" # prompt for key when interactive and no key

OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o-mini}"
OPENAI_API_URL="${OPENAI_API_URL:-https://api.openai.com/v1/chat/completions}"
SYS_PROMPT="You help debug local Kubernetes + GPU tooling issues.

Output rules (this is displayed in a plain terminal, not a browser):
- NO markdown: no **, ##, \`, or backtick fences. Ever.
- Group each issue as: short problem statement, fix command(s), then verification command.
- Separate each group with a blank line.
- Use plain numbered lists (1. 2. 3.) for groups.
- Indent continuation lines with 2 spaces.
- Keep commands on their own line prefixed with \$
- Be concise: max 5-7 groups. Skip issues the user cannot fix (e.g. do not tell them to install an OS they are not running)."

have() { command -v "$1" >/dev/null 2>&1; }
# When this script is used in a pipeline, stdin is not a TTY.
# We still want to allow prompting via /dev/tty if we actually have a controlling TTY.
can_prompt() {
  [[ -t 1 ]] || return 1
  [[ -r /dev/tty ]] || return 1
  # Verify /dev/tty can be opened (not just that it exists).
  true </dev/tty 2>/dev/null || return 1
  return 0
}

while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --title)
      TITLE="${2:-$TITLE}"
      shift 2
      ;;
    --model)
      OPENAI_MODEL="${2:-$OPENAI_MODEL}"
      shift 2
      ;;
    --url)
      OPENAI_API_URL="${2:-$OPENAI_API_URL}"
      shift 2
      ;;
    *)
      # Unknown arg; ignore for forward-compat.
      shift
      ;;
  esac
done

PROMPT="$(cat || true)"
if [[ -z "${PROMPT}" ]]; then
  exit 0
fi

load_saved_key() {
  if [[ -z "${OPENAI_API_KEY:-}" ]] && [[ -f "$KEY_FILE" ]]; then
    OPENAI_API_KEY="$(cat "$KEY_FILE" 2>/dev/null || true)"
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
      export OPENAI_API_KEY
      echo "Loaded API key from ${KEY_FILE}" >&2
    fi
  fi
}

save_key() {
  printf '%s' "$OPENAI_API_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "API key saved to ${KEY_FILE} (chmod 600)" >&2
}

maybe_get_key() {
  load_saved_key

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ "${AI_ASSIST:-}" == "0" ]]; then
    return 0
  fi

  if ! can_prompt; then
    return 0
  fi

  if [[ "${AI_ASSIST_PROMPT}" != "1" ]]; then
    return 0
  fi

  local ans=""
  if [[ "${AI_ASSIST:-}" == "1" ]]; then
    ans="y"
  else
    echo "" >&2
    read -r -p "AI suggestions? [y/N] " ans </dev/tty || true
    case "${ans}" in
      y|Y|yes|YES) ;;
      *) return 0 ;;
    esac
  fi

  echo "Enter OPENAI_API_KEY (input hidden; leave blank to skip)."
  local key=""
  read -r -s -p "OPENAI_API_KEY: " key </dev/tty || true
  echo "" >&2
  if [[ -n "${key}" ]]; then
    OPENAI_API_KEY="${key}"
    export OPENAI_API_KEY
    local save_ans=""
    read -r -p "Save key for future runs? [Y/n] " save_ans </dev/tty || true
    case "${save_ans}" in
      n|N|no|NO) ;;
      *) save_key ;;
    esac
  fi
}

maybe_get_key

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  # If user explicitly forced AI but didn't provide a key, be explicit; otherwise stay quiet.
  if [[ "${AI_ASSIST:-}" == "1" ]]; then
    echo "AI suggestions skipped: OPENAI_API_KEY not set."
  elif can_prompt; then
    # User declined prompt or entered empty key; stay quiet.
    :
  else
    echo ""
    echo "${TITLE} available: set OPENAI_API_KEY=... to enable (no TTY prompt available)."
  fi
  exit 0
fi

if ! have curl; then
  echo ""
  echo "${TITLE} skipped: curl not found."
  exit 0
fi

if ! have python3; then
  echo ""
  echo "${TITLE} skipped: python3 not found (needed to build/parse JSON safely)."
  exit 0
fi

payload="$(
  PROMPT_TEXT="$PROMPT" SYS_PROMPT_TEXT="$SYS_PROMPT" python3 - <<'PY'
import json, os
prompt = os.environ.get("PROMPT_TEXT", "")
sys_prompt = os.environ.get("SYS_PROMPT_TEXT", "You help debug local Kubernetes + GPU tooling issues.")
model = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")
data = {
  "model": model,
  "temperature": 0.2,
  "messages": [
    {"role": "system", "content": sys_prompt},
    {"role": "user", "content": prompt},
  ],
}
print(json.dumps(data))
PY
)"

resp="$(
  curl -sS \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$OPENAI_API_URL" 2>&1
)" || true

extracted="$(
  RESP_TEXT="$resp" python3 - <<'PY'
import json, os
s = os.environ.get("RESP_TEXT", "")
try:
  data = json.loads(s)
except Exception:
  print("")
  raise SystemExit(0)
try:
  print((data.get("choices") or [{}])[0].get("message", {}).get("content", "") or "")
except Exception:
  print("")
PY
)"

echo ""
echo "=========================================="
echo "${TITLE}"
echo "=========================================="
if [[ -n "$extracted" ]]; then
  echo "$extracted"
else
  echo "AI call failed or returned unexpected JSON."
  echo ""
  echo "Raw response (truncated):"
  echo "$resp" | head -c 2000
  echo ""
fi

# Interactive follow-up loop
if [[ -n "$extracted" ]] && can_prompt; then
  CONV_MESSAGES="$(SYS_P="$SYS_PROMPT" USR_P="$PROMPT" ASST_P="$extracted" python3 - <<'PY'
import json, os
print(json.dumps([
  {"role": "system",    "content": os.environ["SYS_P"]},
  {"role": "user",      "content": os.environ["USR_P"]},
  {"role": "assistant", "content": os.environ["ASST_P"]},
]))
PY
  )"

  echo ""
  echo "Ask a follow-up question, or press Ctrl+C to exit."

  trap 'echo ""; exit 0' INT

  while true; do
    echo ""
    read -r -p "> " followup </dev/tty || break
    [[ -z "$followup" ]] && continue

    followup_payload="$(CONV="$CONV_MESSAGES" NEW_MSG="$followup" OPENAI_MODEL="$OPENAI_MODEL" python3 - <<'PY'
import json, os
msgs = json.loads(os.environ["CONV"])
msgs.append({"role": "user", "content": os.environ["NEW_MSG"]})
print(json.dumps({
  "model": os.environ.get("OPENAI_MODEL", "gpt-4o-mini"),
  "temperature": 0.2,
  "messages": msgs,
}))
PY
    )"

    followup_resp="$(curl -sS \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "$followup_payload" \
      "$OPENAI_API_URL" 2>&1)" || true

    reply="$(RESP_TEXT="$followup_resp" python3 - <<'PY'
import json, os
s = os.environ.get("RESP_TEXT", "")
try:
    data = json.loads(s)
except Exception:
    print("")
    raise SystemExit(0)
try:
    print((data.get("choices") or [{}])[0].get("message", {}).get("content", "") or "")
except Exception:
    print("")
PY
    )"

    if [[ -n "$reply" ]]; then
      echo ""
      echo "$reply"
      CONV_MESSAGES="$(CONV="$CONV_MESSAGES" USR="$followup" ASST="$reply" python3 - <<'PY'
import json, os
msgs = json.loads(os.environ["CONV"])
msgs.append({"role": "user", "content": os.environ["USR"]})
msgs.append({"role": "assistant", "content": os.environ["ASST"]})
print(json.dumps(msgs))
PY
      )"
    else
      echo ""
      echo "AI call failed. Try again or press Ctrl+C to exit."
    fi
  done
fi

exit 0

