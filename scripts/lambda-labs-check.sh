#!/usr/bin/env bash

# Lambda Labs Spot GPU VM setup checker for k8s-5-to-8 (P5–P8).
# Setup-only: this script does NOT run P5–P8. It only checks prerequisites and prints PASS/WARN/FAIL.

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: bash is required. Run: bash $0" >&2
  exit 1
fi

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EMIT_CHECKS=0
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --emit-checks) EMIT_CHECKS=1; shift ;;
    *) shift ;;
  esac
done

# Only print when not in --emit-checks mode
display()  { [[ "$EMIT_CHECKS" -eq 0 ]] && echo "$@" || true; }
displaye() { [[ "$EMIT_CHECKS" -eq 0 ]] && echo -e "$@" || true; }

# Toggles (set env vars before running)
RUN_GPU_DOCKER_TEST="${RUN_GPU_DOCKER_TEST:-1}"          # docker run --gpus all ...
RUN_NETWORK_TESTS="${RUN_NETWORK_TESTS:-1}"              # curl Docker Hub + Hugging Face
RUN_DOCKER_PULL_TESTS="${RUN_DOCKER_PULL_TESTS:-0}"      # docker pull vllm image (large)

# Thresholds
MIN_GO_VERSION="${MIN_GO_VERSION:-1.22}"
MIN_FREE_DISK_GB="${MIN_FREE_DISK_GB:-80}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

have() { command -v "$1" >/dev/null 2>&1; }

CHECK_STATUS=()   # PASS | WARN | FAIL | SKIP
CHECK_LABEL=()
CHECK_WHY=()
CHECK_DEBUG=()    # extra context for AI, not printed by default

add_check() {
  CHECK_STATUS+=("$1")
  CHECK_LABEL+=("$2")
  CHECK_WHY+=("${3:-}")
  CHECK_DEBUG+=("${4:-}")
}

print_check() {
  local status="$1" label="$2" why="$3" color="$NC"
  [[ "$status" == "PASS" ]] && color="$GREEN"
  [[ "$status" == "WARN" ]] && color="$YELLOW"
  [[ "$status" == "FAIL" ]] && color="$RED"
  echo -e "${color}${status}${NC} - ${label}${why:+: ${why}}"
}

overall_ok() {
  local s
  for s in "${CHECK_STATUS[@]}"; do
    [[ "$s" == "FAIL" ]] && return 1
  done
  return 0
}

any_warn_or_fail() {
  local s
  for s in "${CHECK_STATUS[@]}"; do
    [[ "$s" == "WARN" || "$s" == "FAIL" ]] && return 0
  done
  return 1
}

version_ge() {
  local a="$1" b="$2" first
  first="$(printf '%s\n' "$b" "$a" | sort -V | head -n 1)"
  [[ "$first" == "$b" ]]
}

curl_code() {
  curl -sS -o /dev/null -L --connect-timeout 3 --max-time 8 -w '%{http_code}' "$1" 2>/dev/null || echo "000"
}

free_disk_gb_root() {
  local avail_kb
  avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' 2>/dev/null || true)"
  [[ -z "$avail_kb" ]] && { echo ""; return 0; }
  echo $(( avail_kb / 1024 / 1024 ))
}

emit_ai_prompt() {
  local i
  echo "Environment check results for a Lambda Labs GPU VM (k8s-5-to-8 repo)."
  echo ""
  echo "Repo root: ${REPO_ROOT}"
  echo "OS: ${os:-unknown}"
  echo "Arch: ${arch:-unknown}"
  echo ""
  echo "Checks:"
  for i in "${!CHECK_STATUS[@]}"; do
    echo "- ${CHECK_STATUS[$i]} | ${CHECK_LABEL[$i]} | ${CHECK_WHY[$i]}"
    if [[ -n "${CHECK_DEBUG[$i]}" ]]; then
      echo "  debug: ${CHECK_DEBUG[$i]}"
    fi
  done
}

display "=========================================="
display "Lambda Labs Spot GPU VM Setup (P5–P8)"
display "Repo: ${REPO_ROOT}"
display "=========================================="
display ""

display "### System"
os="$(uname -s 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"
display "OS:   $os"
display "Arch: $arch"
if [[ "$os" == "Linux" ]]; then
  add_check "PASS" "Linux host" ""
else
  add_check "FAIL" "Linux host" "P5 (Kind+GPU) assumes a Linux GPU host"
fi
display ""

display "### GPU driver (host)"
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then
    gpu="$(nvidia-smi -L 2>/dev/null | head -n 2 | tr '\n' '; ' | sed 's/; $//')"
    add_check "PASS" "nvidia-smi works" "${gpu:-GPU detected}"
  else
    err="$(nvidia-smi -L 2>&1 | head -n 3 | tr '\n' '; ' | sed 's/; $//')"
    add_check "FAIL" "nvidia-smi works" "present but failed" "${err}"
  fi
else
  add_check "FAIL" "nvidia-smi works" "missing (NVIDIA driver not installed)"
fi
display ""

display "### Docker"
docker_user_ok=0
docker_sudo_ok=0
if ! have docker; then
  add_check "FAIL" "docker installed" "missing"
else
  add_check "PASS" "docker installed" "$(docker --version 2>/dev/null || true)"

  if docker info >/dev/null 2>&1; then
    docker_user_ok=1
    add_check "PASS" "docker daemon reachable" "as current user"
  else
    if have sudo && sudo -n docker info >/dev/null 2>&1; then
      docker_sudo_ok=1
      add_check "FAIL" "docker daemon reachable" "works with sudo only (socket permission)"
    else
      err="$(docker info 2>&1 | head -n 3 | tr '\n' '; ' | sed 's/; $//')"
      add_check "FAIL" "docker daemon reachable" "daemon not reachable" "${err}"
    fi
  fi
fi
display ""

display "### NVIDIA Container Toolkit (Docker GPU runtime)"
if [[ "$RUN_GPU_DOCKER_TEST" != "1" ]]; then
  add_check "SKIP" "docker --gpus all works" "RUN_GPU_DOCKER_TEST=0"
elif [[ "$docker_user_ok" -eq 1 ]]; then
  if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    add_check "PASS" "docker --gpus all works" "GPU visible inside containers"
  else
    err="$(docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi 2>&1 | head -n 3 | tr '\n' '; ' | sed 's/; $//')"
    add_check "FAIL" "docker --gpus all works" "GPU not visible in containers" "${err}"
  fi
elif [[ "$docker_sudo_ok" -eq 1 ]]; then
  if have sudo && sudo -n docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    add_check "FAIL" "docker --gpus all works" "works with sudo only (permission issue)"
  else
    add_check "FAIL" "docker --gpus all works" "fails even with sudo"
  fi
else
  add_check "SKIP" "docker --gpus all works" "docker daemon not reachable yet"
fi
display ""

display "### Kubernetes toolchain (P5/P6/P8)"
if have kubectl; then
  add_check "PASS" "kubectl installed" "$(kubectl version --client --short 2>/dev/null || echo kubectl)"
else
  add_check "FAIL" "kubectl installed" "missing"
fi

if have kind; then
  add_check "PASS" "kind installed" "$(kind version 2>/dev/null || echo kind)"
else
  add_check "FAIL" "kind installed" "missing"
fi

if have helm; then
  add_check "PASS" "helm installed" "$(helm version --short 2>/dev/null || echo helm)"
else
  add_check "FAIL" "helm installed" "missing"
fi
display ""

display "### Build toolchain (P7)"
if have go; then
  gv_raw="$(go env GOVERSION 2>/dev/null || true)"
  gv="${gv_raw#go}"
  if [[ -n "$gv" ]] && version_ge "$gv" "$MIN_GO_VERSION"; then
    add_check "PASS" "go >= ${MIN_GO_VERSION}" "$gv_raw"
  else
    add_check "FAIL" "go >= ${MIN_GO_VERSION}" "found ${gv_raw:-unknown}"
  fi
else
  add_check "FAIL" "go >= ${MIN_GO_VERSION}" "missing"
fi

if have make; then
  add_check "PASS" "make installed" "$(make --version 2>/dev/null | head -n 1 || true)"
else
  add_check "WARN" "make installed" "missing"
fi

if have kubebuilder; then
  add_check "PASS" "kubebuilder installed (optional)" "$(kubebuilder version 2>/dev/null | head -n 1 || true)"
else
  add_check "WARN" "kubebuilder installed (optional)" "missing"
fi
display ""

display "### Disk + network (P6)"
free_gb="$(free_disk_gb_root)"
if [[ -n "$free_gb" ]]; then
  if (( free_gb >= MIN_FREE_DISK_GB )); then
    add_check "PASS" "free disk >= ${MIN_FREE_DISK_GB}GB" "free ~${free_gb}GB on /"
  else
    add_check "WARN" "free disk >= ${MIN_FREE_DISK_GB}GB" "free ~${free_gb}GB on /"
  fi
else
  add_check "WARN" "free disk >= ${MIN_FREE_DISK_GB}GB" "could not determine"
fi

if [[ "$RUN_NETWORK_TESTS" != "1" ]]; then
  add_check "SKIP" "HTTPS egress (Docker Hub)" "RUN_NETWORK_TESTS=0"
  add_check "SKIP" "HTTPS egress (Hugging Face)" "RUN_NETWORK_TESTS=0"
else
  if have curl; then
    code="$(curl_code https://registry-1.docker.io/v2/)"
    if [[ "$code" == "401" || "$code" == "200" || "$code" == "301" || "$code" == "302" || "$code" == "403" ]]; then
      add_check "PASS" "HTTPS egress (Docker Hub)" "reachable (HTTP ${code})"
    else
      add_check "WARN" "HTTPS egress (Docker Hub)" "HTTP ${code} (may block pulls)"
    fi

    code="$(curl_code https://huggingface.co/)"
    if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
      add_check "PASS" "HTTPS egress (Hugging Face)" "reachable (HTTP ${code})"
    else
      add_check "WARN" "HTTPS egress (Hugging Face)" "HTTP ${code} (may block model downloads)"
    fi
  else
    add_check "WARN" "HTTPS egress (Docker Hub)" "curl missing"
    add_check "WARN" "HTTPS egress (Hugging Face)" "curl missing"
  fi
fi

if [[ "$RUN_DOCKER_PULL_TESTS" == "1" ]]; then
  if [[ "$docker_user_ok" -eq 1 ]]; then
    if docker pull vllm/vllm-openai:latest >/dev/null 2>&1; then
      add_check "PASS" "docker pull vllm image (optional)" "ok"
    else
      err="$(docker pull vllm/vllm-openai:latest 2>&1 | head -n 3 | tr '\n' '; ' | sed 's/; $//')"
      add_check "WARN" "docker pull vllm image (optional)" "failed" "${err}"
    fi
  else
    add_check "SKIP" "docker pull vllm image (optional)" "docker not usable as current user yet"
  fi
else
  add_check "SKIP" "docker pull vllm image (optional)" "RUN_DOCKER_PULL_TESTS=0"
fi
display ""

# --emit-checks: output machine-readable results and exit
if [[ "$EMIT_CHECKS" -eq 1 ]]; then
  for i in "${!CHECK_STATUS[@]}"; do
    _s="${CHECK_STATUS[$i]}" _l="${CHECK_LABEL[$i]}" _w="${CHECK_WHY[$i]}"
    if [[ -n "$_w" ]]; then
      echo "[${_s}] ${_l} -- ${_w}"
    else
      echo "[${_s}] ${_l}"
    fi
  done
  if overall_ok; then exit 0; else exit 1; fi
fi

echo "=========================================="
echo "Setup Summary"
echo "=========================================="
for i in "${!CHECK_STATUS[@]}"; do
  print_check "${CHECK_STATUS[$i]}" "${CHECK_LABEL[$i]}" "${CHECK_WHY[$i]}"
done
echo ""

echo "=========================================="
echo "Suggested next commands (when you're ready to run projects)"
echo "=========================================="
echo "${REPO_ROOT}/scripts/p5.sh"
echo "${REPO_ROOT}/scripts/p6.sh"
echo "${REPO_ROOT}/scripts/p7.sh"
echo "${REPO_ROOT}/scripts/p8.sh"
echo ""

if overall_ok; then
  echo -e "${GREEN}Overall: PASS${NC} — this VM looks ready to run P5–P8."
else
  echo -e "${YELLOW}Overall: NOT READY${NC} — fix the FAIL items above, then rerun this script."
fi
echo ""

if ! overall_ok; then
  emit_ai_prompt | bash "${REPO_ROOT}/scripts/ai-suggest.sh" \
    --run-fixes \
    --recheck "bash '${REPO_ROOT}/scripts/lambda-labs-check.sh' --emit-checks" \
    --title "AI Suggestions"
  exit 1
fi

exit 0
