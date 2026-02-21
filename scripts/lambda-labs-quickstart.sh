#!/usr/bin/env bash

# Wrapper: the real checker lives in `scripts/lambda-labs-check.sh`.
# This file historically accumulated concatenated draft scripts; we now `exec` the checker
# immediately so nothing below can run.

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: bash is required. Run: bash $0" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/lambda-labs-check.sh" "$@"
exit 1

#!/usr/bin/env bash

# Lambda Labs Spot GPU VM setup checker for k8s-5-to-8 (P5–P8).
# Setup-only: this script does NOT run P5–P8; it only checks prerequisites and prints fixes.

# If invoked as `sh ...`, re-exec under bash (Ubuntu /bin/sh is usually dash).
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: bash is required. Run: bash $0" >&2
  exit 1
fi

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
CHECK_FIX=()

add_check() {
  CHECK_STATUS+=("$1")
  CHECK_LABEL+=("$2")
  CHECK_WHY+=("${3:-}")
  CHECK_FIX+=("${4:-}")
}

print_check() {
  local status="$1" label="$2" why="$3" fix="$4" color="$NC"
  [[ "$status" == "PASS" ]] && color="$GREEN"
  [[ "$status" == "WARN" ]] && color="$YELLOW"
  [[ "$status" == "FAIL" ]] && color="$RED"
  echo -e "${color}${status}${NC} - ${label}${why:+: ${why}}"
  if [[ "$status" != "PASS" && -n "$fix" ]]; then
    echo "  Fix:"
    while IFS= read -r line; do
      echo "    $line"
    done <<< "$fix"
  fi
}

overall_ok() {
  local s
  for s in "${CHECK_STATUS[@]}"; do
    [[ "$s" == "FAIL" ]] && return 1
  done
  return 0
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

echo "=========================================="
echo "Lambda Labs Spot GPU VM Setup (P5–P8)"
echo "Repo: ${REPO_ROOT}"
echo "=========================================="
echo ""

echo "### System"
os="$(uname -s 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"
echo "OS:   $os"
echo "Arch: $arch"
if [[ "$os" == "Linux" ]]; then
  add_check "PASS" "Linux host" "" ""
else
  add_check "FAIL" "Linux host" "P5 (Kind+GPU) assumes a Linux GPU host" ""
fi
echo ""

echo "### GPU driver (host)"
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then
    gpu="$(nvidia-smi -L 2>/dev/null | head -n 2 | tr '\n' '; ' | sed 's/; $//')"
    add_check "PASS" "nvidia-smi works" "${gpu:-GPU detected}" ""
  else
    add_check "FAIL" "nvidia-smi works" "driver present but not healthy" $'sudo nvidia-smi\nsudo dmesg | tail -n 200'
  fi
else
  add_check "FAIL" "nvidia-smi works" "missing (NVIDIA driver not installed)" "On Lambda GPU instances this should exist. If not, reinstall/repair NVIDIA driver."
fi
echo ""

echo "### Docker"
docker_user_ok=0
docker_sudo_ok=0
if ! have docker; then
  add_check "FAIL" "docker installed" "missing" $'sudo apt-get update\nsudo apt-get install -y docker.io\nsudo systemctl enable --now docker'
else
  add_check "PASS" "docker installed" "$(docker --version 2>/dev/null || true)" ""
  if docker info >/dev/null 2>&1; then
    docker_user_ok=1
    add_check "PASS" "docker daemon reachable" "as current user" ""
  else
    if have sudo && sudo -n docker info >/dev/null 2>&1; then
      docker_sudo_ok=1
      add_check "FAIL" "docker daemon reachable" "works with sudo only (socket permission)" $'sudo usermod -aG docker "$(id -un)"\nnewgrp docker   # or logout/login\ndocker info'
    else
      add_check "FAIL" "docker daemon reachable" "daemon not reachable" $'sudo systemctl enable --now docker\nsudo systemctl status docker --no-pager\nsudo journalctl -u docker -n 200 --no-pager'
    fi
  fi
fi
echo ""

echo "### NVIDIA Container Toolkit (Docker GPU runtime)"
if [[ "$RUN_GPU_DOCKER_TEST" != "1" ]]; then
  add_check "SKIP" "docker --gpus all works" "RUN_GPU_DOCKER_TEST=0" ""
elif [[ "$docker_user_ok" -eq 1 ]]; then
  if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    add_check "PASS" "docker --gpus all works" "GPU visible inside containers" ""
  else
    add_check "FAIL" "docker --gpus all works" "GPU not visible in containers" $'sudo nvidia-ctk runtime configure --runtime=docker\nsudo systemctl restart docker\ndocker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  fi
elif [[ "$docker_sudo_ok" -eq 1 ]]; then
  if have sudo && sudo -n docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    add_check "FAIL" "docker --gpus all works" "works with sudo only (still a permission issue)" $'sudo usermod -aG docker "$(id -un)"\nnewgrp docker\ndocker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  else
    add_check "FAIL" "docker --gpus all works" "fails even with sudo" $'sudo nvidia-ctk runtime configure --runtime=docker\nsudo systemctl restart docker\nsudo docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  fi
else
  add_check "SKIP" "docker --gpus all works" "docker daemon not reachable yet" ""
fi
echo ""

echo "### Kubernetes toolchain (P5/P6/P8)"
if have kubectl; then
  add_check "PASS" "kubectl installed" "$(kubectl version --client --short 2>/dev/null || echo kubectl)" ""
else
  add_check "FAIL" "kubectl installed" "missing" $'curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"\nsudo install -m 0755 kubectl /usr/local/bin/kubectl\nrm -f kubectl\nkubectl version --client'
fi

if have kind; then
  add_check "PASS" "kind installed" "$(kind version 2>/dev/null || echo kind)" ""
else
  add_check "FAIL" "kind installed" "missing" $'curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64\nsudo install -m 0755 kind /usr/local/bin/kind\nrm -f kind\nkind version'
fi

if have helm; then
  add_check "PASS" "helm installed" "$(helm version --short 2>/dev/null || echo helm)" ""
else
  add_check "FAIL" "helm installed" "missing" $'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash\nhelm version'
fi
echo ""

echo "### Build toolchain (P7)"
if have go; then
  gv_raw="$(go env GOVERSION 2>/dev/null || true)"
  gv="${gv_raw#go}"
  if [[ -n "$gv" ]] && version_ge "$gv" "$MIN_GO_VERSION"; then
    add_check "PASS" "go >= ${MIN_GO_VERSION}" "$gv_raw" ""
  else
    add_check "FAIL" "go >= ${MIN_GO_VERSION}" "found ${gv_raw:-unknown}" $'curl -fsSLO https://go.dev/dl/go1.22.12.linux-amd64.tar.gz\nsudo rm -rf /usr/local/go\nsudo tar -C /usr/local -xzf go1.22.12.linux-amd64.tar.gz\nrm -f go1.22.12.linux-amd64.tar.gz\necho '\''export PATH=$PATH:/usr/local/go/bin'\'' >> ~/.bashrc\nsource ~/.bashrc\ngo version'
  fi
else
  add_check "FAIL" "go >= ${MIN_GO_VERSION}" "missing" $'curl -fsSLO https://go.dev/dl/go1.22.12.linux-amd64.tar.gz\nsudo rm -rf /usr/local/go\nsudo tar -C /usr/local -xzf go1.22.12.linux-amd64.tar.gz\nrm -f go1.22.12.linux-amd64.tar.gz\necho '\''export PATH=$PATH:/usr/local/go/bin'\'' >> ~/.bashrc\nsource ~/.bashrc\ngo version'
fi

if have make; then
  add_check "PASS" "make installed" "$(make --version 2>/dev/null | head -n 1 || true)" ""
else
  add_check "WARN" "make installed" "missing" "sudo apt-get update && sudo apt-get install -y make"
fi

if have kubebuilder; then
  add_check "PASS" "kubebuilder installed (optional)" "$(kubebuilder version 2>/dev/null | head -n 1 || true)" ""
else
  add_check "WARN" "kubebuilder installed (optional)" "missing" "Optional; only needed if you're doing kubebuilder scaffolding locally."
fi
echo ""

echo "### Disk + network (P6)"
free_gb="$(free_disk_gb_root)"
if [[ -n "$free_gb" ]]; then
  if (( free_gb >= MIN_FREE_DISK_GB )); then
    add_check "PASS" "free disk >= ${MIN_FREE_DISK_GB}GB" "free ~${free_gb}GB on /" ""
  else
    add_check "WARN" "free disk >= ${MIN_FREE_DISK_GB}GB" "free ~${free_gb}GB on /" "Free space is low; P6 model/image downloads may fail."
  fi
else
  add_check "WARN" "free disk >= ${MIN_FREE_DISK_GB}GB" "could not determine" ""
fi

if [[ "$RUN_NETWORK_TESTS" != "1" ]]; then
  add_check "SKIP" "HTTPS egress (Docker Hub)" "RUN_NETWORK_TESTS=0" ""
  add_check "SKIP" "HTTPS egress (Hugging Face)" "RUN_NETWORK_TESTS=0" ""
else
  if have curl; then
    code="$(curl_code https://registry-1.docker.io/v2/)"
    if [[ "$code" == "401" || "$code" == "200" || "$code" == "301" || "$code" == "302" || "$code" == "403" ]]; then
      add_check "PASS" "HTTPS egress (Docker Hub)" "reachable (HTTP ${code})" ""
    else
      add_check "WARN" "HTTPS egress (Docker Hub)" "HTTP ${code} (may block pulls)" $'curl -v https://registry-1.docker.io/v2/\ndocker login   # helps with rate limits'
    fi

    code="$(curl_code https://huggingface.co/)"
    if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
      add_check "PASS" "HTTPS egress (Hugging Face)" "reachable (HTTP ${code})" ""
    else
      add_check "WARN" "HTTPS egress (Hugging Face)" "HTTP ${code} (may block model downloads)" "curl -v https://huggingface.co/"
    fi
  else
    add_check "WARN" "HTTPS egress (Docker Hub)" "curl missing" "sudo apt-get update && sudo apt-get install -y curl"
    add_check "WARN" "HTTPS egress (Hugging Face)" "curl missing" "sudo apt-get update && sudo apt-get install -y curl"
  fi
fi

if [[ "$RUN_DOCKER_PULL_TESTS" == "1" ]]; then
  if [[ "$docker_user_ok" -eq 1 ]]; then
    if docker pull vllm/vllm-openai:latest >/dev/null 2>&1; then
      add_check "PASS" "docker pull vllm image (optional)" "ok" ""
    else
      add_check "WARN" "docker pull vllm image (optional)" "failed" "Try: docker login  (rate limits), then retry."
    fi
  else
    add_check "SKIP" "docker pull vllm image (optional)" "docker not usable as current user yet" ""
  fi
else
  add_check "SKIP" "docker pull vllm image (optional)" "RUN_DOCKER_PULL_TESTS=0" ""
fi
echo ""

echo "=========================================="
echo "Setup Summary"
echo "=========================================="
for i in "${!CHECK_STATUS[@]}"; do
  print_check "${CHECK_STATUS[$i]}" "${CHECK_LABEL[$i]}" "${CHECK_WHY[$i]}" "${CHECK_FIX[$i]}"
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
  exit 0
else
  echo -e "${RED}Overall: FAIL${NC} — fix the FAIL items above, then rerun this checker."
  exit 1
fi

# End.

#!/usr/bin/env bash

# Lambda Labs Spot GPU VM setup checker for k8s-5-to-8 (P5–P8).
# - Setup-only: does NOT create Kind clusters, install charts, or apply manifests.
# - Prints fixes inline for any WARN/FAIL.
#
# You can run this as either:
#   sh lambda-labs-quickstart.sh   (will re-exec into bash)
#   bash lambda-labs-quickstart.sh

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: bash is required. Run: bash $0" >&2
  exit 1
fi

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Toggles
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
CHECK_FIX=()

add_check() {
  CHECK_STATUS+=("$1")
  CHECK_LABEL+=("$2")
  CHECK_WHY+=("${3:-}")
  CHECK_FIX+=("${4:-}")
}

print_check() {
  local status="$1" label="$2" why="$3" fix="$4" color="$NC"
  [[ "$status" == "PASS" ]] && color="$GREEN"
  [[ "$status" == "WARN" ]] && color="$YELLOW"
  [[ "$status" == "FAIL" ]] && color="$RED"
  echo -e "${color}${status}${NC} - ${label}${why:+: ${why}}"
  if [[ "$status" != "PASS" && -n "$fix" ]]; then
    echo "  Fix:"
    while IFS= read -r line; do
      echo "    $line"
    done <<< "$fix"
  fi
}

overall_exit_code() {
  local s
  for s in "${CHECK_STATUS[@]}"; do
    [[ "$s" == "FAIL" ]] && return 1
  done
  return 0
}

version_ge() {
  local a="$1" b="$2"
  local first
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

echo "=========================================="
echo "Lambda Labs Spot GPU VM Setup (P5–P8)"
echo "Repo: ${REPO_ROOT}"
echo "=========================================="
echo ""

echo "### System"
os="$(uname -s 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"
echo "OS:   $os"
echo "Arch: $arch"
if [[ "$os" == "Linux" ]]; then
  add_check "PASS" "Linux host" "" ""
else
  add_check "FAIL" "Linux host" "P5 (Kind+GPU) assumes a Linux GPU host" ""
fi
echo ""

echo "### GPU driver (host)"
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then
    gpu="$(nvidia-smi -L 2>/dev/null | head -n 1 || true)"
    add_check "PASS" "nvidia-smi works" "$gpu" ""
  else
    add_check "FAIL" "nvidia-smi works" "driver present but not healthy" $'sudo nvidia-smi\nsudo dmesg | tail -n 200'
  fi
else
  add_check "FAIL" "nvidia-smi works" "missing (NVIDIA driver not installed)" "On Lambda GPU instances this should exist. If not, reinstall/repair NVIDIA driver."
fi
echo ""

echo "### Docker"
docker_user_ok=0
docker_sudo_ok=0
if ! have docker; then
  add_check "FAIL" "docker installed" "missing" $'sudo apt-get update\nsudo apt-get install -y docker.io\nsudo systemctl enable --now docker'
else
  add_check "PASS" "docker installed" "$(docker --version 2>/dev/null || true)" ""

  if docker info >/dev/null 2>&1; then
    docker_user_ok=1
    add_check "PASS" "docker daemon reachable" "as current user" ""
  else
    if have sudo && sudo -n docker info >/dev/null 2>&1; then
      docker_sudo_ok=1
      add_check "FAIL" "docker daemon reachable" "works with sudo only (socket permission)" $'sudo usermod -aG docker "$(id -un)"\nnewgrp docker   # or logout/login\ndocker info'
    else
      add_check "FAIL" "docker daemon reachable" "daemon not reachable" $'sudo systemctl enable --now docker\nsudo systemctl status docker --no-pager\nsudo journalctl -u docker -n 200 --no-pager'
    fi
  fi
fi
echo ""

echo "### NVIDIA Container Toolkit (Docker GPU runtime)"
if [[ "$RUN_GPU_DOCKER_TEST" != "1" ]]; then
  add_check "SKIP" "docker --gpus all works" "RUN_GPU_DOCKER_TEST=0" ""
elif [[ "$docker_user_ok" -eq 1 ]]; then
  if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    add_check "PASS" "docker --gpus all works" "GPU visible inside containers" ""
  else
    add_check "FAIL" "docker --gpus all works" "GPU not visible in containers" $'sudo nvidia-ctk runtime configure --runtime=docker\nsudo systemctl restart docker\ndocker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  fi
elif [[ "$docker_sudo_ok" -eq 1 ]]; then
  if have sudo && sudo -n docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    add_check "FAIL" "docker --gpus all works" "works with sudo only (still a permission issue)" $'sudo usermod -aG docker "$(id -un)"\nnewgrp docker\ndocker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  else
    add_check "FAIL" "docker --gpus all works" "fails even with sudo" $'sudo nvidia-ctk runtime configure --runtime=docker\nsudo systemctl restart docker\nsudo docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  fi
else
  add_check "SKIP" "docker --gpus all works" "docker daemon not reachable yet" ""
fi
echo ""

echo "### Kubernetes toolchain (P5/P6/P8)"
if have kubectl; then
  add_check "PASS" "kubectl installed" "$(kubectl version --client --short 2>/dev/null || echo kubectl)" ""
else
  add_check "FAIL" "kubectl installed" "missing" $'curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"\nsudo install -m 0755 kubectl /usr/local/bin/kubectl\nrm -f kubectl\nkubectl version --client'
fi

if have kind; then
  add_check "PASS" "kind installed" "$(kind version 2>/dev/null || echo kind)" ""
else
  add_check "FAIL" "kind installed" "missing" $'curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64\nsudo install -m 0755 kind /usr/local/bin/kind\nrm -f kind\nkind version'
fi

if have helm; then
  add_check "PASS" "helm installed" "$(helm version --short 2>/dev/null || echo helm)" ""
else
  add_check "FAIL" "helm installed" "missing" $'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash\nhelm version'
fi
echo ""

echo "### Build toolchain (P7)"
if have go; then
  gv_raw="$(go env GOVERSION 2>/dev/null || true)" # go1.22.12
  gv="${gv_raw#go}"
  if [[ -n "$gv" ]] && version_ge "$gv" "$MIN_GO_VERSION"; then
    add_check "PASS" "go >= ${MIN_GO_VERSION}" "$gv_raw" ""
  else
    add_check "FAIL" "go >= ${MIN_GO_VERSION}" "found ${gv_raw:-unknown}" $'curl -fsSLO https://go.dev/dl/go1.22.12.linux-amd64.tar.gz\nsudo rm -rf /usr/local/go\nsudo tar -C /usr/local -xzf go1.22.12.linux-amd64.tar.gz\nrm -f go1.22.12.linux-amd64.tar.gz\necho '\''export PATH=$PATH:/usr/local/go/bin'\'' >> ~/.bashrc\nsource ~/.bashrc\ngo version'
  fi
else
  add_check "FAIL" "go >= ${MIN_GO_VERSION}" "missing" $'curl -fsSLO https://go.dev/dl/go1.22.12.linux-amd64.tar.gz\nsudo rm -rf /usr/local/go\nsudo tar -C /usr/local -xzf go1.22.12.linux-amd64.tar.gz\nrm -f go1.22.12.linux-amd64.tar.gz\necho '\''export PATH=$PATH:/usr/local/go/bin'\'' >> ~/.bashrc\nsource ~/.bashrc\ngo version'
fi

if have make; then
  add_check "PASS" "make installed" "$(make --version 2>/dev/null | head -n 1 || true)" ""
else
  add_check "WARN" "make installed" "missing" "sudo apt-get update && sudo apt-get install -y make"
fi

if have kubebuilder; then
  add_check "PASS" "kubebuilder installed (optional)" "$(kubebuilder version 2>/dev/null | head -n 1 || true)" ""
else
  add_check "WARN" "kubebuilder installed (optional)" "missing" "Optional; only needed if you're doing kubebuilder scaffolding locally."
fi
echo ""

echo "### Disk + network (P6)"
free_gb="$(free_disk_gb_root)"
if [[ -n "$free_gb" ]]; then
  if (( free_gb >= MIN_FREE_DISK_GB )); then
    add_check "PASS" "free disk >= ${MIN_FREE_DISK_GB}GB" "free ~${free_gb}GB on /" ""
  else
    add_check "WARN" "free disk >= ${MIN_FREE_DISK_GB}GB" "free ~${free_gb}GB on /" "Free space is low; P6 model/image downloads may fail."
  fi
else
  add_check "WARN" "free disk >= ${MIN_FREE_DISK_GB}GB" "could not determine" ""
fi

if [[ "$RUN_NETWORK_TESTS" != "1" ]]; then
  add_check "SKIP" "HTTPS egress (Docker Hub)" "RUN_NETWORK_TESTS=0" ""
  add_check "SKIP" "HTTPS egress (Hugging Face)" "RUN_NETWORK_TESTS=0" ""
else
  if have curl; then
    code="$(curl_code https://registry-1.docker.io/v2/)"
    # 401 is expected when reachable (auth required)
    if [[ "$code" == "401" || "$code" == "200" || "$code" == "301" || "$code" == "302" || "$code" == "403" ]]; then
      add_check "PASS" "HTTPS egress (Docker Hub)" "reachable (HTTP ${code})" ""
    else
      add_check "WARN" "HTTPS egress (Docker Hub)" "HTTP ${code} (may block pulls)" $'curl -v https://registry-1.docker.io/v2/\ndocker login   # helps with rate limits'
    fi

    code="$(curl_code https://huggingface.co/)"
    if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
      add_check "PASS" "HTTPS egress (Hugging Face)" "reachable (HTTP ${code})" ""
    else
      add_check "WARN" "HTTPS egress (Hugging Face)" "HTTP ${code} (may block model downloads)" "curl -v https://huggingface.co/"
    fi
  else
    add_check "WARN" "HTTPS egress (Docker Hub)" "curl missing" "sudo apt-get update && sudo apt-get install -y curl"
    add_check "WARN" "HTTPS egress (Hugging Face)" "curl missing" "sudo apt-get update && sudo apt-get install -y curl"
  fi
fi

if [[ "$RUN_DOCKER_PULL_TESTS" == "1" ]]; then
  if [[ "$docker_user_ok" -eq 1 ]]; then
    if docker pull vllm/vllm-openai:latest >/dev/null 2>&1; then
      add_check "PASS" "docker pull vllm image (optional)" "ok" ""
    else
      add_check "WARN" "docker pull vllm image (optional)" "failed" "Try: docker login  (rate limits), then retry."
    fi
  else
    add_check "SKIP" "docker pull vllm image (optional)" "docker not usable as current user yet" ""
  fi
else
  add_check "SKIP" "docker pull vllm image (optional)" "RUN_DOCKER_PULL_TESTS=0" ""
fi
echo ""

echo "=========================================="
echo "Setup Summary"
echo "=========================================="
for i in "${!CHECK_STATUS[@]}"; do
  print_check "${CHECK_STATUS[$i]}" "${CHECK_LABEL[$i]}" "${CHECK_WHY[$i]}" "${CHECK_FIX[$i]}"
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

if overall_exit_code; then
  echo -e "${GREEN}Overall: PASS${NC} — this VM looks ready to run P5–P8."
  exit 0
else
  echo -e "${RED}Overall: FAIL${NC} — fix the FAIL items above, then rerun this checker."
  exit 1
fi

#!/usr/bin/env bash

# Lambda Labs Spot GPU VM setup checker for k8s-5-to-8 (P5–P8).
# - Setup-only: does NOT create Kind clusters, install charts, or apply manifests.
# - Prints fixes inline for any WARN/FAIL.
#
# You can run this as either:
#   sh lambda-labs-quickstart.sh   (will re-exec into bash)
#   bash lambda-labs-quickstart.sh

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: bash is required. Run: bash $0" >&2
  exit 1
fi

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Toggles
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
CHECK_FIX=()

add_check() {
  CHECK_STATUS+=("$1")
  CHECK_LABEL+=("$2")
  CHECK_WHY+=("${3:-}")
  CHECK_FIX+=("${4:-}")
}

print_check() {
  local status="$1" label="$2" why="$3" fix="$4" color="$NC"
  [[ "$status" == "PASS" ]] && color="$GREEN"
  [[ "$status" == "WARN" ]] && color="$YELLOW"
  [[ "$status" == "FAIL" ]] && color="$RED"
  echo -e "${color}${status}${NC} - ${label}${why:+: ${why}}"
  if [[ "$status" != "PASS" && -n "$fix" ]]; then
    echo "  Fix:"
    # indent each fix line
    while IFS= read -r line; do
      echo "    $line"
    done <<< "$fix"
  fi
}

overall_exit_code() {
  local s
  for s in "${CHECK_STATUS[@]}"; do
    [[ "$s" == "FAIL" ]] && return 1
  done
  return 0
}

version_ge() {
  local a="$1" b="$2"
  local first
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

echo "=========================================="
echo "Lambda Labs Spot GPU VM Setup (P5–P8)"
echo "Repo: ${REPO_ROOT}"
echo "=========================================="
echo ""

echo "### System"
os="$(uname -s 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"
echo "OS:   $os"
echo "Arch: $arch"
if [[ "$os" == "Linux" ]]; then
  add_check "PASS" "Linux host" "" ""
else
  add_check "FAIL" "Linux host" "P5 (Kind+GPU) assumes a Linux GPU host" ""
fi
echo ""

echo "### GPU driver (host)"
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then
    gpu="$(nvidia-smi -L 2>/dev/null | head -n 1 || true)"
    add_check "PASS" "nvidia-smi works" "$gpu" ""
  else
    add_check "FAIL" "nvidia-smi works" "driver present but not healthy" $'sudo nvidia-smi\nsudo dmesg | tail -n 200'
  fi
else
  add_check "FAIL" "nvidia-smi works" "missing (NVIDIA driver not installed)" "On Lambda GPU instances this should exist. If not, reinstall/repair NVIDIA driver."
fi
echo ""

echo "### Docker"
docker_user_ok=0
docker_sudo_ok=0
if ! have docker; then
  add_check "FAIL" "docker installed" "missing" $'sudo apt-get update\nsudo apt-get install -y docker.io\nsudo systemctl enable --now docker'
else
  add_check "PASS" "docker installed" "$(docker --version 2>/dev/null || true)" ""

  if docker info >/dev/null 2>&1; then
    docker_user_ok=1
    add_check "PASS" "docker daemon reachable" "as current user" ""
  else
    if have sudo && sudo -n docker info >/dev/null 2>&1; then
      docker_sudo_ok=1
      add_check "FAIL" "docker daemon reachable" "works with sudo only (socket permission)" $'sudo usermod -aG docker "$(id -un)"\nnewgrp docker   # or logout/login\ndocker info'
    else
      add_check "FAIL" "docker daemon reachable" "daemon not reachable" $'sudo systemctl enable --now docker\nsudo systemctl status docker --no-pager\nsudo journalctl -u docker -n 200 --no-pager'
    fi
  fi
fi
echo ""

echo "### NVIDIA Container Toolkit (Docker GPU runtime)"
if [[ "$RUN_GPU_DOCKER_TEST" != "1" ]]; then
  add_check "SKIP" "docker --gpus all works" "RUN_GPU_DOCKER_TEST=0" ""
elif [[ "$docker_user_ok" -eq 1 ]]; then
  if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    add_check "PASS" "docker --gpus all works" "GPU visible inside containers" ""
  else
    add_check "FAIL" "docker --gpus all works" "GPU not visible in containers" $'sudo nvidia-ctk runtime configure --runtime=docker\nsudo systemctl restart docker\ndocker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  fi
elif [[ "$docker_sudo_ok" -eq 1 ]]; then
  if have sudo && sudo -n docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    add_check "FAIL" "docker --gpus all works" "works with sudo only (still a permission issue)" $'sudo usermod -aG docker "$(id -un)"\nnewgrp docker\ndocker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  else
    add_check "FAIL" "docker --gpus all works" "fails even with sudo" $'sudo nvidia-ctk runtime configure --runtime=docker\nsudo systemctl restart docker\nsudo docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi'
  fi
else
  add_check "SKIP" "docker --gpus all works" "docker daemon not reachable yet" ""
fi
echo ""

echo "### Kubernetes toolchain (P5/P6/P8)"
if have kubectl; then
  add_check "PASS" "kubectl installed" "$(kubectl version --client --short 2>/dev/null || echo kubectl)" ""
else
  add_check "FAIL" "kubectl installed" "missing" $'curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"\nsudo install -m 0755 kubectl /usr/local/bin/kubectl\nrm -f kubectl\nkubectl version --client'
fi

if have kind; then
  add_check "PASS" "kind installed" "$(kind version 2>/dev/null || echo kind)" ""
else
  add_check "FAIL" "kind installed" "missing" $'curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64\nsudo install -m 0755 kind /usr/local/bin/kind\nrm -f kind\nkind version'
fi

if have helm; then
  add_check "PASS" "helm installed" "$(helm version --short 2>/dev/null || echo helm)" ""
else
  add_check "FAIL" "helm installed" "missing" $'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash\nhelm version'
fi
echo ""

echo "### Build toolchain (P7)"
if have go; then
  gv_raw="$(go env GOVERSION 2>/dev/null || true)" # go1.22.12
  gv="${gv_raw#go}"
  if [[ -n "$gv" ]] && version_ge "$gv" "$MIN_GO_VERSION"; then
    add_check "PASS" "go >= ${MIN_GO_VERSION}" "$gv_raw" ""
  else
    add_check "FAIL" "go >= ${MIN_GO_VERSION}" "found ${gv_raw:-unknown}" $'curl -fsSLO https://go.dev/dl/go1.22.12.linux-amd64.tar.gz\nsudo rm -rf /usr/local/go\nsudo tar -C /usr/local -xzf go1.22.12.linux-amd64.tar.gz\nrm -f go1.22.12.linux-amd64.tar.gz\necho \'export PATH=$PATH:/usr/local/go/bin\' >> ~/.bashrc\nsource ~/.bashrc\ngo version'
  fi
else
  add_check "FAIL" "go >= ${MIN_GO_VERSION}" "missing" $'curl -fsSLO https://go.dev/dl/go1.22.12.linux-amd64.tar.gz\nsudo rm -rf /usr/local/go\nsudo tar -C /usr/local -xzf go1.22.12.linux-amd64.tar.gz\nrm -f go1.22.12.linux-amd64.tar.gz\necho \'export PATH=$PATH:/usr/local/go/bin\' >> ~/.bashrc\nsource ~/.bashrc\ngo version'
fi

if have make; then
  add_check "PASS" "make installed" "$(make --version 2>/dev/null | head -n 1 || true)" ""
else
  add_check "WARN" "make installed" "missing" "sudo apt-get update && sudo apt-get install -y make"
fi

if have kubebuilder; then
  add_check "PASS" "kubebuilder installed (optional)" "$(kubebuilder version 2>/dev/null | head -n 1 || true)" ""
else
  add_check "WARN" "kubebuilder installed (optional)" "missing" "Optional; only needed if you're doing kubebuilder scaffolding locally."
fi
echo ""

echo "### Disk + network (P6)"
free_gb="$(free_disk_gb_root)"
if [[ -n "$free_gb" ]]; then
  if (( free_gb >= MIN_FREE_DISK_GB )); then
    add_check "PASS" "free disk >= ${MIN_FREE_DISK_GB}GB" "free ~${free_gb}GB on /" ""
  else
    add_check "WARN" "free disk >= ${MIN_FREE_DISK_GB}GB" "free ~${free_gb}GB on /" "Free space is low; P6 model/image downloads may fail."
  fi
else
  add_check "WARN" "free disk >= ${MIN_FREE_DISK_GB}GB" "could not determine" ""
fi

if [[ "$RUN_NETWORK_TESTS" != "1" ]]; then
  add_check "SKIP" "HTTPS egress (Docker Hub)" "RUN_NETWORK_TESTS=0" ""
  add_check "SKIP" "HTTPS egress (Hugging Face)" "RUN_NETWORK_TESTS=0" ""
else
  if have curl; then
    code="$(curl_code https://registry-1.docker.io/v2/)"
    # 401 is expected when reachable (auth required)
    if [[ "$code" == "401" || "$code" == "200" || "$code" == "301" || "$code" == "302" || "$code" == "403" ]]; then
      add_check "PASS" "HTTPS egress (Docker Hub)" "reachable (HTTP ${code})" ""
    else
      add_check "WARN" "HTTPS egress (Docker Hub)" "HTTP ${code} (may block pulls)" $'curl -v https://registry-1.docker.io/v2/\ndocker login   # helps with rate limits'
    fi

    code="$(curl_code https://huggingface.co/)"
    if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
      add_check "PASS" "HTTPS egress (Hugging Face)" "reachable (HTTP ${code})" ""
    else
      add_check "WARN" "HTTPS egress (Hugging Face)" "HTTP ${code} (may block model downloads)" "curl -v https://huggingface.co/"
    fi
  else
    add_check "WARN" "HTTPS egress (Docker Hub)" "curl missing" "sudo apt-get update && sudo apt-get install -y curl"
    add_check "WARN" "HTTPS egress (Hugging Face)" "curl missing" "sudo apt-get update && sudo apt-get install -y curl"
  fi
fi

if [[ "$RUN_DOCKER_PULL_TESTS" == "1" ]]; then
  if [[ "$docker_user_ok" -eq 1 ]]; then
    if docker pull vllm/vllm-openai:latest >/dev/null 2>&1; then
      add_check "PASS" "docker pull vllm image (optional)" "ok" ""
    else
      add_check "WARN" "docker pull vllm image (optional)" "failed" "Try: docker login  (rate limits), then retry."
    fi
  else
    add_check "SKIP" "docker pull vllm image (optional)" "docker not usable as current user yet" ""
  fi
else
  add_check "SKIP" "docker pull vllm image (optional)" "RUN_DOCKER_PULL_TESTS=0" ""
fi
echo ""

echo "=========================================="
echo "Setup Summary"
echo "=========================================="
for i in "${!CHECK_STATUS[@]}"; do
  print_check "${CHECK_STATUS[$i]}" "${CHECK_LABEL[$i]}" "${CHECK_WHY[$i]}" "${CHECK_FIX[$i]}"
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

if overall_exit_code; then
  echo -e "${GREEN}Overall: PASS${NC} — this VM looks ready to run P5–P8."
  exit 0
else
  echo -e "${RED}Overall: FAIL${NC} — fix the FAIL items above, then rerun this checker."
  exit 1
fi


CHECK_NAMES=()
CHECK_STATUS=()   # PASS | WARN | FAIL | SKIP
CHECK_DETAIL=()

record_check() {
  local name="$1" status="$2" detail="${3:-}"
  CHECK_NAMES+=("$name")
  CHECK_STATUS+=("$status")
  CHECK_DETAIL+=("$detail")
}

section() {
  say ""
  say "=========================================="
  say "$1"
  say "=========================================="
}

status_color() {
  local s="$1"
  case "$s" in
    PASS) echo "$GREEN" ;;
    WARN) echo "$YELLOW" ;;
    FAIL) echo "$RED" ;;
    SKIP) echo "$BLUE" ;;
    *) echo "$NC" ;;
  esac
}

version_ge() {
  local a="$1" b="$2"
  local first
  first="$(printf '%s\n' "$b" "$a" | sort -V | head -n 1)"
  [[ "$first" == "$b" ]]
}

get_free_disk_gb_root() {
  local avail_kb
  avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' 2>/dev/null || true)"
  [[ -z "$avail_kb" ]] && { echo ""; return 0; }
  echo $(( avail_kb / 1024 / 1024 ))
}

curl_ok() {
  curl -fsSIL --connect-timeout 3 --max-time 8 "$1" >/dev/null 2>&1
}

print_summary() {
  section "Setup Summary"
  local i name status detail color
  for i in "${!CHECK_NAMES[@]}"; do
    name="${CHECK_NAMES[$i]}"
    status="${CHECK_STATUS[$i]}"
    detail="${CHECK_DETAIL[$i]}"
    color="$(status_color "$status")"
    if [[ -n "$detail" ]]; then
      say "${color}${status}${NC} - ${name}: ${detail}"
    else
      say "${color}${status}${NC} - ${name}"
    fi
  done

  local any_fail=0
  for status in "${CHECK_STATUS[@]}"; do
    [[ "$status" == "FAIL" ]] && any_fail=1
  done

  say ""
  if [[ "$any_fail" -eq 0 ]]; then
    say "${GREEN}Overall: PASS${NC} — this VM looks ready to run P5–P8."
  else
    say "${RED}Overall: FAIL${NC} — fix the FAIL items above before running P5–P8."
  fi

  say ""
  say "Next steps (when you're ready to run projects):"
  say "  P5: ${REPO_ROOT}/scripts/p5.sh"
  say "  P6: ${REPO_ROOT}/scripts/p6.sh"
  say "  P7: ${REPO_ROOT}/scripts/p7.sh"
  say "  P8: ${REPO_ROOT}/scripts/p8.sh"
  say ""

  return "$any_fail"
}

say "=========================================="
say "Lambda Labs Spot GPU VM Setup (P5–P8)"
say "Repo: ${REPO_ROOT}"
say "=========================================="

section "System"
os="$(uname -s 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"
say "OS:   ${os}"
say "Arch: ${arch}"
if [[ "$os" == "Linux" ]]; then
  record_check "Linux host" "PASS" ""
else
  record_check "Linux host" "FAIL" "P5 (Kind+GPU) assumes a Linux GPU host"
fi

section "GPU driver (host)"
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then
    gpu_list="$(nvidia-smi -L 2>/dev/null | head -n 2 | tr '\n' '; ' | sed 's/; $//')"
    record_check "nvidia-smi works" "PASS" "${gpu_list:-GPU detected}"
  else
    record_check "nvidia-smi works" "FAIL" "nvidia-smi present but failed (driver not healthy)"
  fi
else
  record_check "nvidia-smi works" "FAIL" "missing nvidia-smi (NVIDIA driver not installed)"
fi

section "Docker"
if ! have docker; then
  record_check "docker installed" "FAIL" "install Docker Engine"
else
  record_check "docker installed" "PASS" "$(docker --version 2>/dev/null || true)"
  if docker info >/dev/null 2>&1; then
    record_check "docker daemon reachable" "PASS" ""
  else
    record_check "docker daemon reachable" "FAIL" "start docker service / check permissions"
  fi
fi

section "NVIDIA Container Toolkit (Docker GPU runtime)"
if [[ "$RUN_GPU_DOCKER_TEST" != "1" ]]; then
  record_check "docker --gpus all works" "SKIP" "RUN_GPU_DOCKER_TEST=0"
elif have docker; then
  if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    record_check "docker --gpus all works" "PASS" "GPU accessible inside containers"
  else
    record_check "docker --gpus all works" "FAIL" "NVIDIA Container Toolkit not configured (or driver/runtime mismatch)"
  fi
else
  record_check "docker --gpus all works" "SKIP" "docker missing"
fi

section "Kubernetes toolchain (P5/P6/P8)"
if have kubectl; then
  record_check "kubectl installed" "PASS" "$(kubectl version --client --short 2>/dev/null || echo "kubectl present")"
else
  record_check "kubectl installed" "FAIL" "install kubectl"
fi

if have kind; then
  record_check "kind installed" "PASS" "$(kind version 2>/dev/null || true)"
else
  record_check "kind installed" "FAIL" "install kind"
fi

if have helm; then
  record_check "helm installed" "PASS" "$(helm version --short 2>/dev/null || helm version 2>/dev/null || echo "helm present")"
else
  record_check "helm installed" "FAIL" "install helm"
fi

section "Build toolchain (P7/P8)"
if have go; then
  go_ver_raw="$(go env GOVERSION 2>/dev/null || true)"
  go_ver="${go_ver_raw#go}"
  if [[ -n "$go_ver" ]] && version_ge "$go_ver" "$MIN_GO_VERSION"; then
    record_check "go >= ${MIN_GO_VERSION}" "PASS" "$go_ver_raw"
  else
    record_check "go >= ${MIN_GO_VERSION}" "FAIL" "found ${go_ver_raw:-unknown}; install Go ${MIN_GO_VERSION}+"
  fi
else
  record_check "go >= ${MIN_GO_VERSION}" "FAIL" "install Go ${MIN_GO_VERSION}+"
fi

if have make; then
  record_check "make installed" "PASS" "$(make --version 2>/dev/null | head -n 1 || true)"
else
  record_check "make installed" "WARN" "recommended"
fi

if have kubebuilder; then
  record_check "kubebuilder installed" "PASS" "$(kubebuilder version 2>/dev/null | head -n 1 || true)"
else
  record_check "kubebuilder installed" "WARN" "recommended for Project 7 development"
fi

section "Disk + network (P6: vLLM)"
free_gb="$(get_free_disk_gb_root)"
if [[ -n "$free_gb" ]]; then
  if (( free_gb >= MIN_FREE_DISK_GB )); then
    record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "PASS" "free ~${free_gb}GB on /"
  else
    record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "WARN" "free ~${free_gb}GB on / (models + images may fill disk)"
  fi
else
  record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "WARN" "could not determine free disk"
fi

if [[ "$RUN_NETWORK_TESTS" != "1" ]]; then
  record_check "HTTPS egress (Docker Hub)" "SKIP" "RUN_NETWORK_TESTS=0"
  record_check "HTTPS egress (Hugging Face)" "SKIP" "RUN_NETWORK_TESTS=0"
elif have curl; then
  if curl_ok "https://registry-1.docker.io/v2/"; then
    record_check "HTTPS egress (Docker Hub)" "PASS" ""
  else
    record_check "HTTPS egress (Docker Hub)" "WARN" "cannot reach Docker Hub (may break image pulls)"
  fi

  if curl_ok "https://huggingface.co/"; then
    record_check "HTTPS egress (Hugging Face)" "PASS" ""
  else
    record_check "HTTPS egress (Hugging Face)" "WARN" "cannot reach Hugging Face (may break model downloads)"
  fi
else
  record_check "HTTPS egress (Docker Hub)" "WARN" "curl not found; cannot test"
  record_check "HTTPS egress (Hugging Face)" "WARN" "curl not found; cannot test"
fi

if [[ "$RUN_DOCKER_PULL_TESTS" == "1" ]]; then
  section "Optional: Docker pull test (can be large)"
  if have docker && docker pull vllm/vllm-openai:latest >/dev/null 2>&1; then
    record_check "docker pull vllm/vllm-openai:latest" "PASS" ""
  else
    record_check "docker pull vllm/vllm-openai:latest" "WARN" "pull failed (network/registry/auth)"
  fi
else
  record_check "docker pull vllm image (optional)" "SKIP" "RUN_DOCKER_PULL_TESTS=0"
fi

print_summary
exit $?
#!/usr/bin/env bash

# NOTE: Users sometimes run this as `sh lambda-labs-quickstart.sh` (dash).
# Re-exec under bash if not already running in bash.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "ERROR: bash is required. Run: bash $0" >&2
  exit 1
fi

set -uo pipefail

# Lambda Labs Spot GPU VM: setup-only quickstart for Projects 5–8.
#
# This script does NOT run P5–P8 (no Kind cluster creation, no kubectl apply).
# It only checks whether your VM is ready to run:
# - P5: Kind + NVIDIA GPU Operator + CUDA Pod
# - P6: vLLM serving (needs network + disk + Docker pulls)
# - P7: Go operator build tooling
# - P8: Webhook build tooling (Docker) + cluster tooling (Kind/Helm)
#
# Output:
# - PASS: requirement satisfied
# - WARN: not strictly required for all projects, but recommended / may block some scenarios
# - FAIL: will block at least one of P5–P8
#
# Exit code:
# - 0: no FAIL checks
# - 1: one or more FAIL checks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Toggles (set env vars before running)
RUN_GPU_DOCKER_TEST="${RUN_GPU_DOCKER_TEST:-1}"          # docker run --gpus all ...
RUN_NETWORK_TESTS="${RUN_NETWORK_TESTS:-1}"              # curl to Docker Hub + Hugging Face
RUN_DOCKER_PULL_TESTS="${RUN_DOCKER_PULL_TESTS:-0}"      # docker pull vllm image (can be large)
MIN_GO_VERSION="${MIN_GO_VERSION:-1.22}"                 # P7/P8 tooling
MIN_FREE_DISK_GB="${MIN_FREE_DISK_GB:-80}"               # rough suggestion for P6 models/images

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

say() { echo -e "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

CHECK_NAMES=()
CHECK_STATUS=()   # PASS | WARN | FAIL | SKIP
CHECK_DETAIL=()

record_check() {
  local name="$1" status="$2" detail="${3:-}"
  CHECK_NAMES+=("$name")
  CHECK_STATUS+=("$status")
  CHECK_DETAIL+=("$detail")
}

section() {
  say ""
  say "=========================================="
  say "$1"
  say "=========================================="
}

status_color() {
  local s="$1"
  case "$s" in
    PASS) echo "$GREEN" ;;
    WARN) echo "$YELLOW" ;;
    FAIL) echo "$RED" ;;
    SKIP) echo "$BLUE" ;;
    *) echo "$NC" ;;
  esac
}

version_ge() {
  # version_ge <a> <b>  => true if a >= b, using sort -V
  local a="$1" b="$2"
  local first
  first="$(printf '%s\n' "$b" "$a" | sort -V | head -n 1)"
  [[ "$first" == "$b" ]]
}

get_free_disk_gb_root() {
  # Returns integer GiB-ish free space on / (best-effort).
  local avail_kb
  avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' 2>/dev/null || true)"
  if [[ -z "$avail_kb" ]]; then
    echo ""
    return 0
  fi
  echo $(( avail_kb / 1024 / 1024 ))
}

curl_ok() {
  # curl_ok <url>
  curl -fsSIL --connect-timeout 3 --max-time 8 "$1" >/dev/null 2>&1
}

print_summary() {
  section "Setup Summary"
  local i name status detail color
  for i in "${!CHECK_NAMES[@]}"; do
    name="${CHECK_NAMES[$i]}"
    status="${CHECK_STATUS[$i]}"
    detail="${CHECK_DETAIL[$i]}"
    color="$(status_color "$status")"
    if [[ -n "$detail" ]]; then
      say "${color}${status}${NC} - ${name}: ${detail}"
    else
      say "${color}${status}${NC} - ${name}"
    fi
  done

  local any_fail=0
  for status in "${CHECK_STATUS[@]}"; do
    [[ "$status" == "FAIL" ]] && any_fail=1
  done

  say ""
  if [[ "$any_fail" -eq 0 ]]; then
    say "${GREEN}Overall: PASS${NC} — this VM looks ready to run P5–P8."
  else
    say "${RED}Overall: FAIL${NC} — fix the FAIL items above before running P5–P8."
  fi

  say ""
  say "Next steps (when you're ready to run projects):"
  say "  P5: ${REPO_ROOT}/scripts/p5.sh"
  say "  P6: ${REPO_ROOT}/scripts/p6.sh"
  say "  P7: ${REPO_ROOT}/scripts/p7.sh"
  say "  P8: ${REPO_ROOT}/scripts/p8.sh"
  say ""

  return "$any_fail"
}

say "=========================================="
say "Lambda Labs Spot GPU VM Setup (P5–P8)"
say "Repo: ${REPO_ROOT}"
say "=========================================="

section "System"
os="$(uname -s 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"
say "OS:   ${os}"
say "Arch: ${arch}"
if [[ "$os" == "Linux" ]]; then
  record_check "Linux host" "PASS" ""
else
  record_check "Linux host" "FAIL" "P5 (Kind+GPU) assumes a Linux GPU host"
fi

section "GPU driver (host)"
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then
    gpu_list="$(nvidia-smi -L 2>/dev/null | head -n 2 | tr '\n' '; ' | sed 's/; $//')"
    record_check "nvidia-smi works" "PASS" "${gpu_list:-GPU detected}"
  else
    record_check "nvidia-smi works" "FAIL" "nvidia-smi present but failed (driver not healthy)"
  fi
else
  record_check "nvidia-smi works" "FAIL" "missing nvidia-smi (NVIDIA driver not installed)"
fi

section "Docker"
if ! have docker; then
  record_check "docker installed" "FAIL" "install Docker Engine"
else
  record_check "docker installed" "PASS" "$(docker --version 2>/dev/null || true)"
  if docker info >/dev/null 2>&1; then
    record_check "docker daemon reachable" "PASS" ""
  else
    record_check "docker daemon reachable" "FAIL" "run 'sudo systemctl start docker' (or check permissions)"
  fi
fi

section "NVIDIA Container Toolkit (Docker GPU runtime)"
if [[ "$RUN_GPU_DOCKER_TEST" != "1" ]]; then
  record_check "docker --gpus all works" "SKIP" "RUN_GPU_DOCKER_TEST=0"
else
  if have docker; then
    if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
      record_check "docker --gpus all works" "PASS" "GPU accessible inside containers"
    else
      record_check "docker --gpus all works" "FAIL" "NVIDIA Container Toolkit not configured (or driver/runtime mismatch)"
    fi
  else
    record_check "docker --gpus all works" "SKIP" "docker missing"
  fi
fi

section "Kubernetes toolchain (P5/P6/P8)"
if have kubectl; then
  record_check "kubectl installed" "PASS" "$(kubectl version --client --short 2>/dev/null || echo "kubectl present")"
else
  record_check "kubectl installed" "FAIL" "install kubectl"
fi

if have kind; then
  record_check "kind installed" "PASS" "$(kind version 2>/dev/null || true)"
else
  record_check "kind installed" "FAIL" "install kind"
fi

if have helm; then
  record_check "helm installed" "PASS" "$(helm version --short 2>/dev/null || helm version 2>/dev/null || echo "helm present")"
else
  record_check "helm installed" "FAIL" "install helm (needed for GPU Operator + cert-manager)"
fi

section "Build toolchain (P7/P8)"
if have go; then
  go_ver_raw="$(go env GOVERSION 2>/dev/null || true)" # e.g. go1.22.0
  go_ver="${go_ver_raw#go}"
  if [[ -n "$go_ver" ]] && version_ge "$go_ver" "$MIN_GO_VERSION"; then
    record_check "go >= ${MIN_GO_VERSION}" "PASS" "$go_ver_raw"
  else
    record_check "go >= ${MIN_GO_VERSION}" "FAIL" "found ${go_ver_raw:-unknown}; install Go ${MIN_GO_VERSION}+"
  fi
else
  record_check "go >= ${MIN_GO_VERSION}" "FAIL" "install Go ${MIN_GO_VERSION}+"
fi

if have make; then
  record_check "make installed" "PASS" "$(make --version 2>/dev/null | head -n 1 || true)"
else
  record_check "make installed" "WARN" "recommended for operator/webhook workflows"
fi

if have kubebuilder; then
  record_check "kubebuilder installed" "PASS" "$(kubebuilder version 2>/dev/null | head -n 1 || true)"
else
  record_check "kubebuilder installed" "WARN" "Project 7 docs mention kubebuilder; repo scripts can still run without it"
fi

section "Disk + network (P6: vLLM)"
free_gb="$(get_free_disk_gb_root)"
if [[ -n "$free_gb" ]]; then
  if (( free_gb >= MIN_FREE_DISK_GB )); then
    record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "PASS" "free ~${free_gb}GB on /"
  else
    record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "WARN" "free ~${free_gb}GB on / (models + images may fill disk)"
  fi
else
  record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "WARN" "could not determine free disk"
fi

if [[ "$RUN_NETWORK_TESTS" != "1" ]]; then
  record_check "HTTPS egress (Docker Hub)" "SKIP" "RUN_NETWORK_TESTS=0"
  record_check "HTTPS egress (Hugging Face)" "SKIP" "RUN_NETWORK_TESTS=0"
else
  if have curl; then
    if curl_ok "https://registry-1.docker.io/v2/"; then
      record_check "HTTPS egress (Docker Hub)" "PASS" ""
    else
      record_check "HTTPS egress (Docker Hub)" "WARN" "curl could not reach Docker Hub (may break image pulls)"
    fi

    if curl_ok "https://huggingface.co/"; then
      record_check "HTTPS egress (Hugging Face)" "PASS" ""
    else
      record_check "HTTPS egress (Hugging Face)" "WARN" "curl could not reach Hugging Face (may break model downloads)"
    fi
  else
    record_check "HTTPS egress (Docker Hub)" "WARN" "curl not found; cannot test egress"
    record_check "HTTPS egress (Hugging Face)" "WARN" "curl not found; cannot test egress"
  fi
fi

if [[ "$RUN_DOCKER_PULL_TESTS" == "1" ]]; then
  section "Optional: Docker pull test (can be large)"
  if have docker; then
    if docker pull vllm/vllm-openai:latest >/dev/null 2>&1; then
      record_check "docker pull vllm/vllm-openai:latest" "PASS" ""
    else
      record_check "docker pull vllm/vllm-openai:latest" "WARN" "pull failed (network/registry/auth)"
    fi
  else
    record_check "docker pull vllm/vllm-openai:latest" "SKIP" "docker missing"
  fi
else
  record_check "docker pull vllm image (optional)" "SKIP" "RUN_DOCKER_PULL_TESTS=0"
fi

print_summary
exit $?
have() { command -v "$1" >/dev/null 2>&1; }

CHECK_NAMES=()
CHECK_STATUS=()   # PASS | WARN | FAIL | SKIP
CHECK_DETAIL=()

record_check() {
  local name="$1" status="$2" detail="${3:-}"
  CHECK_NAMES+=("$name")
  CHECK_STATUS+=("$status")
  CHECK_DETAIL+=("$detail")
}

section() {
  say ""
  say "=========================================="
  say "$1"
  say "=========================================="
}

status_color() {
  local s="$1"
  case "$s" in
    PASS) echo "$GREEN" ;;
    WARN) echo "$YELLOW" ;;
    FAIL) echo "$RED" ;;
    SKIP) echo "$BLUE" ;;
    *) echo "$NC" ;;
  esac
}

version_ge() {
  # version_ge <a> <b>  => true if a >= b, using sort -V
  local a="$1" b="$2"
  local first
  first="$(printf '%s\n' "$b" "$a" | sort -V | head -n 1)"
  [[ "$first" == "$b" ]]
}

get_free_disk_gb_root() {
  # Returns integer GiB-ish free space on / (best-effort).
  local avail_kb
  avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' 2>/dev/null || true)"
  if [[ -z "$avail_kb" ]]; then
    echo ""
    return 0
  fi
  echo $(( avail_kb / 1024 / 1024 ))
}

curl_ok() {
  # curl_ok <url>
  curl -fsSIL --connect-timeout 3 --max-time 8 "$1" >/dev/null 2>&1
}

print_summary() {
  section "Setup Summary"
  local i name status detail color
  for i in "${!CHECK_NAMES[@]}"; do
    name="${CHECK_NAMES[$i]}"
    status="${CHECK_STATUS[$i]}"
    detail="${CHECK_DETAIL[$i]}"
    color="$(status_color "$status")"
    if [[ -n "$detail" ]]; then
      say "${color}${status}${NC} - ${name}: ${detail}"
    else
      say "${color}${status}${NC} - ${name}"
    fi
  done

  local any_fail=0
  for status in "${CHECK_STATUS[@]}"; do
    [[ "$status" == "FAIL" ]] && any_fail=1
  done

  say ""
  if [[ "$any_fail" -eq 0 ]]; then
    say "${GREEN}Overall: PASS${NC} — this VM looks ready to run P5–P8."
  else
    say "${RED}Overall: FAIL${NC} — fix the FAIL items above before running P5–P8."
  fi

  say ""
  say "Next steps (when you're ready to run projects):"
  say "  P5: ${REPO_ROOT}/scripts/p5.sh"
  say "  P6: ${REPO_ROOT}/scripts/p6.sh"
  say "  P7: ${REPO_ROOT}/scripts/p7.sh"
  say "  P8: ${REPO_ROOT}/scripts/p8.sh"
  say ""

  return "$any_fail"
}

say "=========================================="
say "Lambda Labs Spot GPU VM Setup (P5–P8)"
say "Repo: ${REPO_ROOT}"
say "=========================================="

section "System"
os="$(uname -s 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"
say "OS:   ${os}"
say "Arch: ${arch}"
if [[ "$os" == "Linux" ]]; then
  record_check "Linux host" "PASS" ""
else
  record_check "Linux host" "FAIL" "P5 (Kind+GPU) assumes a Linux GPU host"
fi

section "GPU driver (host)"
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then
    gpu_list="$(nvidia-smi -L 2>/dev/null | head -n 2 | tr '\n' '; ' | sed 's/; $//')"
    record_check "nvidia-smi works" "PASS" "${gpu_list:-GPU detected}"
  else
    record_check "nvidia-smi works" "FAIL" "nvidia-smi present but failed (driver not healthy)"
  fi
else
  record_check "nvidia-smi works" "FAIL" "missing nvidia-smi (NVIDIA driver not installed)"
fi

section "Docker"
if ! have docker; then
  record_check "docker installed" "FAIL" "install Docker Engine"
else
  record_check "docker installed" "PASS" "$(docker --version 2>/dev/null || true)"
  if docker info >/dev/null 2>&1; then
    record_check "docker daemon reachable" "PASS" ""
  else
    record_check "docker daemon reachable" "FAIL" "run 'sudo systemctl start docker' (or check permissions)"
  fi
fi

section "NVIDIA Container Toolkit (Docker GPU runtime)"
if [[ "$RUN_GPU_DOCKER_TEST" != "1" ]]; then
  record_check "docker --gpus all works" "SKIP" "RUN_GPU_DOCKER_TEST=0"
else
  if have docker; then
    if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
      record_check "docker --gpus all works" "PASS" "GPU accessible inside containers"
    else
      record_check "docker --gpus all works" "FAIL" "NVIDIA Container Toolkit not configured (or driver/runtime mismatch)"
    fi
  else
    record_check "docker --gpus all works" "SKIP" "docker missing"
  fi
fi

section "Kubernetes toolchain (P5/P6/P8)"
if have kubectl; then
  record_check "kubectl installed" "PASS" "$(kubectl version --client --short 2>/dev/null || echo "kubectl present")"
else
  record_check "kubectl installed" "FAIL" "install kubectl"
fi

if have kind; then
  record_check "kind installed" "PASS" "$(kind version 2>/dev/null || true)"
else
  record_check "kind installed" "FAIL" "install kind"
fi

if have helm; then
  record_check "helm installed" "PASS" "$(helm version --short 2>/dev/null || helm version 2>/dev/null || echo "helm present")"
else
  record_check "helm installed" "FAIL" "install helm (needed for GPU Operator + cert-manager)"
fi

section "Build toolchain (P7/P8)"
if have go; then
  go_ver_raw="$(go env GOVERSION 2>/dev/null || true)" # e.g. go1.22.0
  go_ver="${go_ver_raw#go}"
  if [[ -n "$go_ver" ]] && version_ge "$go_ver" "$MIN_GO_VERSION"; then
    record_check "go >= ${MIN_GO_VERSION}" "PASS" "$go_ver_raw"
  else
    record_check "go >= ${MIN_GO_VERSION}" "FAIL" "found ${go_ver_raw:-unknown}; install Go ${MIN_GO_VERSION}+"
  fi
else
  record_check "go >= ${MIN_GO_VERSION}" "FAIL" "install Go ${MIN_GO_VERSION}+"
fi

if have make; then
  record_check "make installed" "PASS" "$(make --version 2>/dev/null | head -n 1 || true)"
else
  record_check "make installed" "WARN" "recommended for operator/webhook workflows"
fi

if have kubebuilder; then
  record_check "kubebuilder installed" "PASS" "$(kubebuilder version 2>/dev/null | head -n 1 || true)"
else
  record_check "kubebuilder installed" "WARN" "Project 7 docs mention kubebuilder; repo scripts can still run without it"
fi

section "Disk + network (P6: vLLM)"
free_gb="$(get_free_disk_gb_root)"
if [[ -n "$free_gb" ]]; then
  if (( free_gb >= MIN_FREE_DISK_GB )); then
    record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "PASS" "free ~${free_gb}GB on /"
  else
    record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "WARN" "free ~${free_gb}GB on / (models + images may fill disk)"
  fi
else
  record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "WARN" "could not determine free disk"
fi

if [[ "$RUN_NETWORK_TESTS" != "1" ]]; then
  record_check "HTTPS egress (Docker Hub)" "SKIP" "RUN_NETWORK_TESTS=0"
  record_check "HTTPS egress (Hugging Face)" "SKIP" "RUN_NETWORK_TESTS=0"
else
  if have curl; then
    if curl_ok "https://registry-1.docker.io/v2/"; then
      record_check "HTTPS egress (Docker Hub)" "PASS" ""
    else
      record_check "HTTPS egress (Docker Hub)" "WARN" "curl could not reach Docker Hub (may break image pulls)"
    fi

    if curl_ok "https://huggingface.co/"; then
      record_check "HTTPS egress (Hugging Face)" "PASS" ""
    else
      record_check "HTTPS egress (Hugging Face)" "WARN" "curl could not reach Hugging Face (may break model downloads)"
    fi
  else
    record_check "HTTPS egress (Docker Hub)" "WARN" "curl not found; cannot test egress"
    record_check "HTTPS egress (Hugging Face)" "WARN" "curl not found; cannot test egress"
  fi
fi

if [[ "$RUN_DOCKER_PULL_TESTS" == "1" ]]; then
  section "Optional: Docker pull test (can be large)"
  if have docker; then
    if docker pull vllm/vllm-openai:latest >/dev/null 2>&1; then
      record_check "docker pull vllm/vllm-openai:latest" "PASS" ""
    else
      record_check "docker pull vllm/vllm-openai:latest" "WARN" "pull failed (network/registry/auth)"
    fi
  else
    record_check "docker pull vllm/vllm-openai:latest" "SKIP" "docker missing"
  fi
else
  record_check "docker pull vllm image (optional)" "SKIP" "RUN_DOCKER_PULL_TESTS=0"
fi

print_summary
exit $?

# Toggles (set env vars before running)
RUN_GPU_DOCKER_TEST="${RUN_GPU_DOCKER_TEST:-1}"          # docker run --gpus all ...
RUN_NETWORK_TESTS="${RUN_NETWORK_TESTS:-1}"              # curl to Docker Hub + Hugging Face
RUN_DOCKER_PULL_TESTS="${RUN_DOCKER_PULL_TESTS:-0}"      # docker pull vllm image (can be large)
MIN_GO_VERSION="${MIN_GO_VERSION:-1.22}"                 # P7/P8 tooling
MIN_FREE_DISK_GB="${MIN_FREE_DISK_GB:-80}"               # rough suggestion for P6 models/images

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

say() { echo -e "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

CHECK_NAMES=()
CHECK_STATUS=()   # PASS | WARN | FAIL | SKIP
CHECK_DETAIL=()

record_check() {
  local name="$1" status="$2" detail="${3:-}"
  CHECK_NAMES+=("$name")
  CHECK_STATUS+=("$status")
  CHECK_DETAIL+=("$detail")
}

section() {
  say ""
  say "=========================================="
  say "$1"
  say "=========================================="
}

status_color() {
  local s="$1"
  case "$s" in
    PASS) echo "$GREEN" ;;
    WARN) echo "$YELLOW" ;;
    FAIL) echo "$RED" ;;
    SKIP) echo "$BLUE" ;;
    *) echo "$NC" ;;
  esac
}

version_ge() {
  # version_ge <a> <b>  => true if a >= b, using sort -V
  local a="$1" b="$2"
  local first
  first="$(printf '%s\n' "$b" "$a" | sort -V | head -n 1)"
  [[ "$first" == "$b" ]]
}

get_free_disk_gb_root() {
  # Returns integer GiB-ish free space on / (best-effort).
  local avail_kb
  avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' 2>/dev/null || true)"
  if [[ -z "$avail_kb" ]]; then
    echo ""
    return 0
  fi
  echo $(( avail_kb / 1024 / 1024 ))
}

curl_ok() {
  # curl_ok <url>
  curl -fsSIL --connect-timeout 3 --max-time 8 "$1" >/dev/null 2>&1
}

print_summary() {
  section "Setup Summary"
  local i name status detail color
  for i in "${!CHECK_NAMES[@]}"; do
    name="${CHECK_NAMES[$i]}"
    status="${CHECK_STATUS[$i]}"
    detail="${CHECK_DETAIL[$i]}"
    color="$(status_color "$status")"
    if [[ -n "$detail" ]]; then
      say "${color}${status}${NC} - ${name}: ${detail}"
    else
      say "${color}${status}${NC} - ${name}"
    fi
  done

  local any_fail=0
  for status in "${CHECK_STATUS[@]}"; do
    [[ "$status" == "FAIL" ]] && any_fail=1
  done

  say ""
  if [[ "$any_fail" -eq 0 ]]; then
    say "${GREEN}Overall: PASS${NC} — this VM looks ready to run P5–P8."
  else
    say "${RED}Overall: FAIL${NC} — fix the FAIL items above before running P5–P8."
  fi

  say ""
  say "Next steps (when you're ready to run projects):"
  say "  P5: ${REPO_ROOT}/scripts/p5.sh"
  say "  P6: ${REPO_ROOT}/scripts/p6.sh"
  say "  P7: ${REPO_ROOT}/scripts/p7.sh"
  say "  P8: ${REPO_ROOT}/scripts/p8.sh"
  say ""
}

say "=========================================="
say "Lambda Labs Spot GPU VM Setup (P5–P8)"
say "Repo: ${REPO_ROOT}"
say "=========================================="

section "System"
os="$(uname -s 2>/dev/null || true)"
arch="$(uname -m 2>/dev/null || true)"
say "OS:   ${os}"
say "Arch: ${arch}"
if [[ "$os" == "Linux" ]]; then
  record_check "Linux host" "PASS" ""
else
  record_check "Linux host" "FAIL" "P5 (Kind+GPU) assumes a Linux GPU host"
fi

section "GPU driver (host)"
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then
    gpu_list="$(nvidia-smi -L 2>/dev/null | head -n 2 | tr '\n' '; ' | sed 's/; $//')"
    record_check "nvidia-smi works" "PASS" "${gpu_list:-GPU detected}"
  else
    record_check "nvidia-smi works" "FAIL" "nvidia-smi present but failed (driver not healthy)"
  fi
else
  record_check "nvidia-smi works" "FAIL" "missing nvidia-smi (NVIDIA driver not installed)"
fi

section "Docker"
if ! have docker; then
  record_check "docker installed" "FAIL" "install Docker Engine"
else
  record_check "docker installed" "PASS" "$(docker --version 2>/dev/null || true)"
  if docker info >/dev/null 2>&1; then
    record_check "docker daemon reachable" "PASS" ""
  else
    record_check "docker daemon reachable" "FAIL" "run 'sudo systemctl start docker' (or check permissions)"
  fi
fi

section "NVIDIA Container Toolkit (Docker GPU runtime)"
if [[ "$RUN_GPU_DOCKER_TEST" != "1" ]]; then
  record_check "docker --gpus all works" "SKIP" "RUN_GPU_DOCKER_TEST=0"
else
  if have docker; then
    if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
      record_check "docker --gpus all works" "PASS" "GPU accessible inside containers"
    else
      record_check "docker --gpus all works" "FAIL" "NVIDIA Container Toolkit not configured (or driver/runtime mismatch)"
    fi
  else
    record_check "docker --gpus all works" "SKIP" "docker missing"
  fi
fi

section "Kubernetes toolchain (P5/P6/P8)"
if have kubectl; then
  record_check "kubectl installed" "PASS" "$(kubectl version --client --short 2>/dev/null || echo "kubectl present")"
else
  record_check "kubectl installed" "FAIL" "install kubectl"
fi

if have kind; then
  record_check "kind installed" "PASS" "$(kind version 2>/dev/null || true)"
else
  record_check "kind installed" "FAIL" "install kind"
fi

if have helm; then
  record_check "helm installed" "PASS" "$(helm version --short 2>/dev/null || helm version 2>/dev/null || echo "helm present")"
else
  record_check "helm installed" "FAIL" "install helm (needed for GPU Operator + cert-manager)"
fi

section "Build toolchain (P7/P8)"
if have go; then
  go_ver_raw="$(go env GOVERSION 2>/dev/null || true)" # e.g. go1.22.0
  go_ver="${go_ver_raw#go}"
  if [[ -n "$go_ver" ]] && version_ge "$go_ver" "$MIN_GO_VERSION"; then
    record_check "go >= ${MIN_GO_VERSION}" "PASS" "$go_ver_raw"
  else
    record_check "go >= ${MIN_GO_VERSION}" "FAIL" "found ${go_ver_raw:-unknown}; install Go ${MIN_GO_VERSION}+"
  fi
else
  record_check "go >= ${MIN_GO_VERSION}" "FAIL" "install Go ${MIN_GO_VERSION}+"
fi

if have make; then
  record_check "make installed" "PASS" "$(make --version 2>/dev/null | head -n 1 || true)"
else
  record_check "make installed" "WARN" "recommended for operator/webhook workflows"
fi

if have kubebuilder; then
  record_check "kubebuilder installed" "PASS" "$(kubebuilder version 2>/dev/null | head -n 1 || true)"
else
  record_check "kubebuilder installed" "WARN" "Project 7 docs mention kubebuilder; repo scripts can still run without it"
fi

section "Disk + network (P6: vLLM)"
free_gb="$(get_free_disk_gb_root)"
if [[ -n "$free_gb" ]]; then
  if (( free_gb >= MIN_FREE_DISK_GB )); then
    record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "PASS" "free ~${free_gb}GB on /"
  else
    record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "WARN" "free ~${free_gb}GB on / (models + images may fill disk)"
  fi
else
  record_check "free disk >= ${MIN_FREE_DISK_GB}GB" "WARN" "could not determine free disk"
fi

if [[ "$RUN_NETWORK_TESTS" != "1" ]]; then
  record_check "HTTPS egress (Docker Hub)" "SKIP" "RUN_NETWORK_TESTS=0"
  record_check "HTTPS egress (Hugging Face)" "SKIP" "RUN_NETWORK_TESTS=0"
else
  if have curl; then
    if curl_ok "https://registry-1.docker.io/v2/"; then
      record_check "HTTPS egress (Docker Hub)" "PASS" ""
    else
      record_check "HTTPS egress (Docker Hub)" "WARN" "curl could not reach Docker Hub (may break image pulls)"
    fi

    if curl_ok "https://huggingface.co/"; then
      record_check "HTTPS egress (Hugging Face)" "PASS" ""
    else
      record_check "HTTPS egress (Hugging Face)" "WARN" "curl could not reach Hugging Face (may break model downloads)"
    fi
  else
    record_check "HTTPS egress (Docker Hub)" "WARN" "curl not found; cannot test egress"
    record_check "HTTPS egress (Hugging Face)" "WARN" "curl not found; cannot test egress"
  fi
fi

if [[ "$RUN_DOCKER_PULL_TESTS" == "1" ]]; then
  section "Optional: Docker pull test (can be large)"
  if have docker; then
    if docker pull vllm/vllm-openai:latest >/dev/null 2>&1; then
      record_check "docker pull vllm/vllm-openai:latest" "PASS" ""
    else
      record_check "docker pull vllm/vllm-openai:latest" "WARN" "pull failed (network/registry/auth)"
    fi
  else
    record_check "docker pull vllm/vllm-openai:latest" "SKIP" "docker missing"
  fi
else
  record_check "docker pull vllm image (optional)" "SKIP" "RUN_DOCKER_PULL_TESTS=0"
fi

print_summary
exit $?

# P6 knobs
HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-}"
VLLM_MODEL="${VLLM_MODEL:-}"
VLLM_NAMESPACE="${VLLM_NAMESPACE:-vllm}"
VLLM_ROLLOUT_TIMEOUT_SECONDS="${VLLM_ROLLOUT_TIMEOUT_SECONDS:-900}"
REPO_DEFAULT_VLLM_MODEL="meta-llama/Llama-2-7b-chat-hf"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

say() { echo -e "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

STAGE_NAMES=()
STAGE_STATUS=()  # PASS | FAIL | SKIP
STAGE_DETAIL=()

record_stage() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  STAGE_NAMES+=("$name")
  STAGE_STATUS+=("$status")
  STAGE_DETAIL+=("$detail")
}

stage_header() {
  local title="$1"
  say ""
  say "=========================================="
  say "$title"
  say "=========================================="
}

run_cmd() {
  # run_cmd "<desc>" <command...>
  local desc="$1"
  shift
  say "${YELLOW}→ ${desc}${NC}"
  "$@"
}

choose_vllm_model() {
  if [[ -n "$VLLM_MODEL" ]]; then
    return 0
  fi

  # Default to an open model unless the user provided an HF token.
  # Repo default is Llama-2; that often fails without HF auth + acceptance.
  if [[ -n "$HUGGING_FACE_HUB_TOKEN" ]]; then
    VLLM_MODEL="$REPO_DEFAULT_VLLM_MODEL"
  else
    VLLM_MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
  fi
}

kind_kubeconfig_ready() {
  kind get kubeconfig --name "$CLUSTER_NAME" >/dev/null 2>&1
}

gpu_allocatable_table() {
  # Prints: "<node>\t<gpuAlloc>" (gpuAlloc may be empty)
  kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name}{\"\t\"}{.status.allocatable['nvidia.com/gpu']}{\"\n\"}{end}" 2>/dev/null || true
}

count_gpu_nodes() {
  local line name gpu count=0
  while IFS=$'\t' read -r name gpu; do
    [[ -z "$name" ]] && continue
    [[ -z "$gpu" ]] && continue
    [[ "$gpu" == "0" ]] && continue
    count=$((count + 1))
  done < <(gpu_allocatable_table)
  echo "$count"
}

default_storage_class() {
  # Prefer default StorageClass; otherwise return first SC; empty if none.
  local sc default first
  default="$(kubectl get storageclass -o jsonpath="{range .items[?(@.metadata.annotations['storageclass.kubernetes.io/is-default-class']=='true')]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$default" ]]; then
    echo "$default"
    return 0
  fi

  first="$(kubectl get storageclass -o jsonpath="{range .items[*]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null | head -n 1 || true)"
  echo "$first"
}

wait_for_pvc_bound() {
  # wait_for_pvc_bound <namespace> <pvcName> <timeoutSeconds>
  local ns="$1" pvc="$2" timeout="${3:-120}"
  local start now phase
  start="$(date +%s)"
  while true; do
    phase="$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath="{.status.phase}" 2>/dev/null || true)"
    [[ "$phase" == "Bound" ]] && return 0
    now="$(date +%s)"
    if (( now - start > timeout )); then
      return 1
    fi
    sleep 3
  done
}

print_summary() {
  stage_header "Quickstart Summary"
  local i name status detail color
  for i in "${!STAGE_NAMES[@]}"; do
    name="${STAGE_NAMES[$i]}"
    status="${STAGE_STATUS[$i]}"
    detail="${STAGE_DETAIL[$i]}"
    color="$NC"
    [[ "$status" == "PASS" ]] && color="$GREEN"
    [[ "$status" == "FAIL" ]] && color="$RED"
    [[ "$status" == "SKIP" ]] && color="$YELLOW"
    if [[ -n "$detail" ]]; then
      say "${color}${status}${NC} - ${name}: ${detail}"
    else
      say "${color}${status}${NC} - ${name}"
    fi
  done
  say ""
}

say "=========================================="
say "Tutorial: k8s-5-to-8 (P5–P7) on Lambda"
say "Repo: ${REPO_ROOT}"
say "Kind cluster name: ${CLUSTER_NAME}"
say "=========================================="
say ""

stage_header "Preflight: required tools"
missing=0
have kubectl || { say "${RED}Missing:${NC} kubectl"; missing=1; }
have docker || { say "${RED}Missing:${NC} docker"; missing=1; }
have kind || { say "${RED}Missing:${NC} kind"; missing=1; }
have helm || { say "${RED}Missing:${NC} helm"; missing=1; }

if [[ "$missing" -eq 1 ]]; then
  record_stage "Preflight" "FAIL" "Install missing tools above, then rerun"
  print_summary
  exit 1
fi
record_stage "Preflight" "PASS" "kubectl/docker/kind/helm present"

stage_header "Preflight: host GPU runtime (best-effort)"
if [[ "$(uname -s)" == "Linux" ]]; then
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    say "${GREEN}✓ Host NVIDIA GPU detected (nvidia-smi works)${NC}"
  else
    say "${YELLOW}WARN: nvidia-smi not available on host; GPU scheduling will likely not work.${NC}"
    say "${YELLOW}      You can still run the flow, but GPU Pods may stay Pending.${NC}"
  fi

  if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    say "${GREEN}✓ Docker GPU runtime looks OK (docker --gpus all works)${NC}"
  else
    say "${YELLOW}WARN: docker --gpus all failed (NVIDIA Container Toolkit may not be configured).${NC}"
    say "${YELLOW}      The GPU Operator/device plugin may install, but pods may not get GPUs.${NC}"
  fi
else
  say "${YELLOW}Note: Non-Linux host detected; skipping host GPU runtime checks.${NC}"
fi

##
## Stage: P5
##
if [[ "$RUN_P5" == "1" ]]; then
  stage_header "P5: Kind multi-node + NVIDIA GPU Operator + CUDA pod"
  export KIND_CLUSTER_NAME="$CLUSTER_NAME"
  if run_cmd "Run Project 5 script" bash "$SCRIPT_DIR/p5.sh"; then
    record_stage "P5" "PASS" "CUDA pod applied; check logs for nvidia-smi output"
  else
    record_stage "P5" "FAIL" "See output above (cluster create / operator install / pod scheduling)"
  fi
else
  record_stage "P5" "SKIP" "RUN_P5=0"
fi

##
## Stage: P6
##
if [[ "$RUN_P6" == "1" ]]; then
  stage_header "P6: vLLM Deployment + Service + HPA"
  choose_vllm_model

  if ! kind_kubeconfig_ready; then
    record_stage "P6" "SKIP" "Kind cluster '$CLUSTER_NAME' not found (run P5 first or set RUN_P5=1)"
  else
    gpu_nodes="$(count_gpu_nodes)"
    if [[ "$gpu_nodes" -eq 0 ]]; then
      say "${YELLOW}WARN: No nodes advertise allocatable nvidia.com/gpu yet.${NC}"
      say "${YELLOW}      If P5's CUDA pod was Pending, GPU Operator/device plugin may not be ready.${NC}"
    else
      say "${GREEN}✓ Detected ${gpu_nodes} node(s) with allocatable nvidia.com/gpu${NC}"
    fi

    sc="$(default_storage_class)"
    if [[ -z "$sc" ]]; then
      record_stage "P6" "SKIP" "No StorageClass found; PVC will not bind"
    else
      say "${GREEN}✓ StorageClass detected: ${sc}${NC}"
      say "${YELLOW}Using model:${NC} ${VLLM_MODEL}"
      if [[ -z "$HUGGING_FACE_HUB_TOKEN" ]]; then
        say "${YELLOW}Note:${NC} no HUGGING_FACE_HUB_TOKEN set; using an open model default to avoid gated downloads."
        say "${YELLOW}      Override with:${NC} VLLM_MODEL=meta-llama/Llama-2-7b-chat-hf HUGGING_FACE_HUB_TOKEN=... $0"
      fi

      # Apply namespace + PVC
      if ! run_cmd "Apply namespace/PVC/service/HPA" bash -c \
        "kubectl apply -f \"$REPO_ROOT/k8s/06-vllm/namespace.yaml\" && \
         kubectl apply -f \"$REPO_ROOT/k8s/06-vllm/vllm-pvc.yaml\" && \
         kubectl apply -f \"$REPO_ROOT/k8s/06-vllm/vllm-service.yaml\" && \
         kubectl apply -f \"$REPO_ROOT/k8s/06-vllm/vllm-hpa.yaml\""; then
        record_stage "P6" "FAIL" "kubectl apply failed for one or more manifests"
      else
        if ! wait_for_pvc_bound "$VLLM_NAMESPACE" "vllm-hf-cache" 180; then
          say "${YELLOW}WARN: PVC did not reach Bound within timeout.${NC}"
          say "${YELLOW}      Check:${NC} kubectl get pvc -n ${VLLM_NAMESPACE} && kubectl describe pvc -n ${VLLM_NAMESPACE} vllm-hf-cache"
        fi

        # Apply deployment with optional model override.
        p6_deploy_applied=0
        if ! have python3; then
          if [[ "$VLLM_MODEL" != "$REPO_DEFAULT_VLLM_MODEL" ]]; then
            record_stage "P6" "SKIP" "python3 not found; needed to override model (install python3 or set VLLM_MODEL=$REPO_DEFAULT_VLLM_MODEL)"
          elif run_cmd "Apply vLLM deployment (repo default model=${REPO_DEFAULT_VLLM_MODEL})" \
            kubectl apply -f "$REPO_ROOT/k8s/06-vllm/vllm-deployment.yaml"; then
            p6_deploy_applied=1
          else
            record_stage "P6" "FAIL" "Failed applying vLLM deployment"
          fi
        elif run_cmd "Apply vLLM deployment (model=${VLLM_MODEL})" bash -c \
          "python3 - \"$REPO_ROOT/k8s/06-vllm/vllm-deployment.yaml\" \"$VLLM_MODEL\" <<'PY' | kubectl apply -f -
import re,sys
path=sys.argv[1]
model=sys.argv[2]
s=open(path,'r',encoding='utf-8').read()
s2=re.sub(r'(\\s*-\\s*\"--model=)([^\"]+)(\")', lambda m: m.group(1)+model+m.group(3), s, count=1)
print(s2)
PY"; then
          p6_deploy_applied=1
        else
          record_stage "P6" "FAIL" "Failed applying vLLM deployment"
        fi

        if [[ "$p6_deploy_applied" -eq 1 ]]; then
          if [[ -n "$HUGGING_FACE_HUB_TOKEN" ]]; then
            run_cmd "Set HF token on Deployment" kubectl -n "$VLLM_NAMESPACE" set env deployment/vllm "HUGGING_FACE_HUB_TOKEN=$HUGGING_FACE_HUB_TOKEN" >/dev/null 2>&1 || true
          fi

          if run_cmd "Wait for rollout (timeout ${VLLM_ROLLOUT_TIMEOUT_SECONDS}s)" \
            kubectl rollout status deployment/vllm -n "$VLLM_NAMESPACE" --timeout="${VLLM_ROLLOUT_TIMEOUT_SECONDS}s"; then
            record_stage "P6" "PASS" "vLLM rolled out; port-forward svc/vllm 8000:8000 then call /v1/completions"
          else
            say "${YELLOW}Rollout did not complete; dumping pod status (best-effort).${NC}"
            kubectl get pods -n "$VLLM_NAMESPACE" -o wide || true
            kubectl describe deploy/vllm -n "$VLLM_NAMESPACE" 2>/dev/null | tail -n 80 || true
            record_stage "P6" "FAIL" "Rollout timeout/failure (image pull, model download, insufficient resources, PVC, etc.)"
          fi
        fi
      fi
    fi
  fi
else
  record_stage "P6" "SKIP" "RUN_P6=0"
fi

##
## Stage: P7
##
if [[ "$RUN_P7" == "1" ]]; then
  stage_header "P7: Operator preflight (CRD + build sanity)"
  if ! have go; then
    record_stage "P7" "SKIP" "go not found (install Go 1.22+ to build the operator)"
  else
    go_ver="$(go env GOVERSION 2>/dev/null || true)"
    say "${GREEN}✓ Go detected:${NC} ${go_ver}"

    if run_cmd "Apply InferenceDeployment CRD" kubectl apply -f "$REPO_ROOT/operator/config/crd/bases/ml.example.com_inferencedeployments.yaml"; then
      if run_cmd "Build operator (no deploy)" bash -c "cd \"$REPO_ROOT/operator\" && go build -o /tmp/manager-quickstart ./main.go"; then
        record_stage "P7" "PASS" "CRD applied + operator builds (run scripts/p7.sh to run the controller)"
      else
        record_stage "P7" "FAIL" "CRD applied but build failed (Go deps/toolchain issue)"
      fi
    else
      record_stage "P7" "FAIL" "Failed applying CRD (cluster permissions?)"
    fi
  fi
else
  record_stage "P7" "SKIP" "RUN_P7=0"
fi

##
## Stage: P8 (optional)
##
if [[ "$RUN_P8" == "1" ]]; then
  stage_header "P8: Webhooks (optional)"
  if run_cmd "Run Project 8 script" bash "$SCRIPT_DIR/p8.sh"; then
    record_stage "P8" "PASS" "cert-manager + webhook stack applied"
  else
    record_stage "P8" "FAIL" "See output above (cert-manager/webhook image/CA bundle)"
  fi
else
  record_stage "P8" "SKIP" "RUN_P8=0"
fi

print_summary
__DUPLICATE__