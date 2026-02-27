#!/usr/bin/env bash

# Generic optional OpenAI "suggest fixes" helper for shell scripts.
#
# Usage:
#   Text mode:  <prompt> | scripts/ai-suggest.sh [--title "AI Suggestions"]
#   Fix mode:   <prompt> | scripts/ai-suggest.sh --run-fixes [--recheck "cmd"] [--title "..."]
#
# Text mode (default): Sends prompt to AI, displays response, offers follow-up chat.
# Fix mode (--run-fixes): Parses FAIL items from prompt, fixes one at a time.
#   AI returns JSON with one command per response. User approves each command.
#   If --recheck is given, re-runs the check command after each fix to verify.
#
# Key management:
# - If OPENAI_API_KEY is set: will call OpenAI.
# - Else if interactive and AI_ASSIST_PROMPT=1: asks whether to enable, then prompts for key.
# - Otherwise: does nothing (no network).

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
RUN_FIXES=0
RECHECK_CMD=""

AI_ASSIST="${AI_ASSIST:-}"                 # set to 1 to force AI (requires key); 0 to disable prompts
AI_ASSIST_PROMPT="${AI_ASSIST_PROMPT:-1}" # prompt for key when interactive and no key

OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o-mini}"
OPENAI_API_URL="${OPENAI_API_URL:-https://api.openai.com/v1/chat/completions}"

# System prompt for text mode
TEXT_SYS_PROMPT="You help debug local Kubernetes + GPU tooling issues.

Output rules (this is displayed in a plain terminal, not a browser):
- NO markdown: no **, ##, \`, or backtick fences. Ever.
- Group each issue as: short problem statement, fix command(s), then verification command.
- Separate each group with a blank line.
- Use plain numbered lists (1. 2. 3.) for groups.
- Indent continuation lines with 2 spaces.
- Keep commands on their own line prefixed with \$
- Be concise: max 5-7 groups. Skip issues the user cannot fix (e.g. do not tell them to install an OS they are not running)."

# System prompt for fix mode (AI returns JSON, one command at a time)
FIX_SYS_PROMPT='You help fix issues on Lambda Labs GPU VMs (Ubuntu Linux) for the k8s-5-to-8 repo.

You will be given environment check results and asked to fix a specific failing check.
Return your response as a JSON object (no markdown fences, no extra text):
{
  "explanation": "what is wrong and why this command will fix it",
  "command": "single shell command to run"
}

Rules:
- Return exactly ONE command at a time.
- Commands must be safe and non-destructive.
- Prefer apt-get, snap, curl+install, or usermod for system changes.
- If the fix requires multiple steps, return only the FIRST step.
  You will be called again with updated results after each step.
- If a previous attempt failed, try a different approach.
- Keep explanations concise (1-2 sentences).'

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

# --- Arg parsing ---
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --title)      TITLE="${2:-$TITLE}"; shift 2 ;;
    --model)      OPENAI_MODEL="${2:-$OPENAI_MODEL}"; shift 2 ;;
    --url)        OPENAI_API_URL="${2:-$OPENAI_API_URL}"; shift 2 ;;
    --run-fixes)  RUN_FIXES=1; shift ;;
    --recheck)    RECHECK_CMD="${2:-}"; shift 2 ;;
    *)            shift ;;  # Unknown arg; ignore for forward-compat.
  esac
done

# --- Read stdin ---
PROMPT="$(cat || true)"
if [[ -z "${PROMPT}" ]]; then
  exit 0
fi

# --- Key management ---
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
  if [[ "${AI_ASSIST:-}" == "1" ]]; then
    echo "AI suggestions skipped: OPENAI_API_KEY not set."
  elif can_prompt; then
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

# --- API helper ---
# Call OpenAI with a JSON messages array string. Prints the response content text.
call_ai() {
  local messages="$1"
  local payload
  payload="$(MSGS="$messages" OPENAI_MODEL="$OPENAI_MODEL" python3 - <<'PY'
import json, os
msgs = json.loads(os.environ["MSGS"])
print(json.dumps({
  "model": os.environ.get("OPENAI_MODEL", "gpt-4o-mini"),
  "temperature": 0.2,
  "messages": msgs,
}))
PY
  )"

  local resp
  resp="$(curl -sS \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$OPENAI_API_URL" 2>&1)" || true

  RESP_TEXT="$resp" python3 - <<'PY'
import json, os
s = os.environ.get("RESP_TEXT", "")
try:
  data = json.loads(s)
  print((data.get("choices") or [{}])[0].get("message", {}).get("content", "") or "")
except Exception:
  print("")
PY
}

# --- Fix mode ---

# Parse JSON from AI response, stripping markdown fences if present.
# Prints valid JSON or empty string.
parse_fix_json() {
  local content="$1"
  CONTENT="$content" python3 - <<'PY'
import json, os
c = os.environ.get("CONTENT", "").strip()
if c.startswith("```"):
    lines = c.split("\n")
    lines = lines[1:]  # remove opening fence line
    if lines and lines[-1].strip().startswith("```"):
        lines = lines[:-1]
    c = "\n".join(lines).strip()
try:
    d = json.loads(c)
    print(json.dumps(d))
except Exception:
    print("")
PY
}

# Main fix loop: parse FAILs from prompt, fix each one with AI guidance.
run_fixes() {
  local prompt="$1"

  # Parse FAIL items from the prompt.
  # Format from emit_ai_prompt: "- FAIL | label | why"
  local -a fail_labels=()
  local -a fail_whys=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
    if [[ "$line" == "- FAIL | "* ]]; then
      local rest="${line#- FAIL | }"
      local label why=""
      if [[ "$rest" == *" | "* ]]; then
        label="${rest%% | *}"
        why="${rest#* | }"
      else
        label="$rest"
      fi
      label="${label%"${label##*[![:space:]]}"}"  # trim trailing whitespace
      why="${why%"${why##*[![:space:]]}"}"
      fail_labels+=("$label")
      fail_whys+=("$why")
    fi
  done <<< "$prompt"

  if [[ ${#fail_labels[@]} -eq 0 ]]; then
    echo "No FAIL items found in check results."
    return 0
  fi

  local fixed=0
  local skipped=0
  local total=${#fail_labels[@]}

  for idx in "${!fail_labels[@]}"; do
    local label="${fail_labels[$idx]}"
    local why="${fail_whys[$idx]}"
    local issue_desc="${label}${why:+ -- ${why}}"

    echo ""
    echo "=========================================="
    echo "Fixing: ${issue_desc}"
    echo "=========================================="

    # Build initial conversation for this issue
    local conv
    conv="$(FIX_SYS="$FIX_SYS_PROMPT" PROMPT_TEXT="$prompt" ISSUE="$issue_desc" python3 - <<'PY'
import json, os
print(json.dumps([
  {"role": "system", "content": os.environ["FIX_SYS"]},
  {"role": "user", "content": os.environ["PROMPT_TEXT"] + "\n\nFix this specific issue: " + os.environ["ISSUE"]},
]))
PY
    )"

    local max_retries=5
    local attempt=0
    local issue_fixed=0

    while [[ $attempt -lt $max_retries ]]; do
      attempt=$((attempt + 1))

      # Call AI
      local ai_raw
      ai_raw="$(call_ai "$conv")"

      if [[ -z "$ai_raw" ]]; then
        echo ""
        echo "    AI call failed. Skipping this issue."
        break
      fi

      # Parse JSON response
      local ai_json
      ai_json="$(parse_fix_json "$ai_raw")"

      if [[ -z "$ai_json" ]]; then
        echo ""
        echo "    AI returned unexpected format. Skipping this issue."
        echo "    Response: ${ai_raw:0:500}"
        break
      fi

      # Extract fields
      local explanation command
      explanation="$(echo "$ai_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('explanation',''))" 2>/dev/null || true)"
      command="$(echo "$ai_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('command',''))" 2>/dev/null || true)"

      if [[ -z "$command" ]]; then
        echo ""
        echo "    AI didn't suggest a command. Skipping."
        break
      fi

      # Display
      echo ""
      if [[ -n "$explanation" ]]; then
        echo "$explanation"
        echo ""
      fi
      echo "    Command: $command"

      # Non-interactive: just show commands, don't run
      if ! can_prompt; then
        echo "    (non-interactive mode: command not executed)"
        # In non-interactive mode, show all commands but don't run or recheck
        break
      fi

      # Get user approval
      local ans=""
      read -r -p "    Run? [Y/n] " ans </dev/tty || true
      case "$ans" in
        n|N|no|NO)
          echo "    Skipped by user."
          break
          ;;
      esac

      # Run command
      echo -n "    Running... "
      local cmd_output cmd_exit=0
      cmd_output="$(eval "$command" 2>&1)" || cmd_exit=$?
      if [[ $cmd_exit -eq 0 ]]; then
        echo "OK"
      else
        echo "exited with code ${cmd_exit}"
      fi

      # Recheck if we have a recheck command
      if [[ -n "$RECHECK_CMD" ]]; then
        echo ""
        echo -n "    Re-checking... "
        local recheck_output
        recheck_output="$(eval "$RECHECK_CMD" 2>&1)" || true

        # Check if this specific issue is now PASS
        if echo "$recheck_output" | grep -qF "[PASS] ${label}"; then
          echo "PASS"
          issue_fixed=1
          break
        else
          echo "still FAIL"

          # Update conversation: tell AI what we tried and the new results
          conv="$(CONV="$conv" AI_RESP="$ai_raw" CMD="$command" EXIT="$cmd_exit" \
            CMD_OUT="${cmd_output:0:500}" RECHECK="$recheck_output" ISSUE="$issue_desc" python3 - <<'PY'
import json, os
msgs = json.loads(os.environ["CONV"])
msgs.append({"role": "assistant", "content": os.environ["AI_RESP"]})
info = "I ran that command but the issue is still failing."
info += "\n\nCommand: " + os.environ["CMD"]
info += "\nExit code: " + os.environ["EXIT"]
out = os.environ.get("CMD_OUT", "")
if out:
    info += "\nOutput (truncated):\n" + out
info += "\n\nUpdated check results:\n" + os.environ["RECHECK"]
info += "\n\nTry a different approach to fix: " + os.environ["ISSUE"]
msgs.append({"role": "user", "content": info})
print(json.dumps(msgs))
PY
          )"
        fi
      else
        # No recheck command; assume success after running
        issue_fixed=1
        break
      fi
    done

    if [[ $issue_fixed -eq 1 ]]; then
      fixed=$((fixed + 1))
    else
      skipped=$((skipped + 1))
      if [[ $attempt -ge $max_retries ]]; then
        echo ""
        echo "    Gave up after ${max_retries} attempts."
      fi
    fi
  done

  # Final summary
  echo ""
  echo "=========================================="
  if [[ $skipped -eq 0 && $fixed -gt 0 ]]; then
    echo "All issues resolved!"
  elif [[ $fixed -gt 0 ]]; then
    echo "Fixed ${fixed}/${total} issues. ${skipped} remain."
  else
    echo "No issues were fixed."
  fi
  echo "=========================================="
}

# --- Main: branch between fix mode and text mode ---

if [[ "$RUN_FIXES" -eq 1 ]]; then
  run_fixes "$PROMPT"

  # Offer follow-up conversation after fix mode
  if can_prompt; then
    # Build conversation context from the fix session
    CONV_MESSAGES="$(FIX_SYS="$FIX_SYS_PROMPT" USR_P="$PROMPT" python3 - <<'PY'
import json, os
print(json.dumps([
  {"role": "system", "content": os.environ["FIX_SYS"]},
  {"role": "user", "content": os.environ["USR_P"]},
]))
PY
    )"

    echo ""
    echo "Ask a follow-up question, or press Enter to exit."

    trap 'echo ""; exit 0' INT

    while true; do
      echo ""
      read -r -p "> " followup </dev/tty || break
      [[ -z "$followup" ]] && break

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
        echo "AI call failed. Try again or press Enter to exit."
      fi
    done
  fi

else
  # --- Text mode (existing behavior) ---
  SYS_PROMPT="$TEXT_SYS_PROMPT"

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
fi

exit 0
