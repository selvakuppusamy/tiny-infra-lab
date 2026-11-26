#!/bin/bash
# Manages a disposable Multipass Ubuntu LTS VM that hosts 1..N isolated GitHub Actions runner agents.

# Session-scoped VM and runner state tracked so partial failures or Ctrl+C still clean up cleanly.
CREATED_VM=""
REGISTERED_RUNNERS=()
STARTED_RUNNER_PIDS=()
HOST_STAGE_DIR=""
SESSION_DIR=""
SESSION_NAME=""
RUNNER_OS="linux"
RUNNER_ARCH=""

# Lightweight VM resource defaults (override via env vars when a workflow needs heavier compute).
VM_IMAGE="${VM_IMAGE:-lts}"
VM_CPUS="${VM_CPUS:-2}"
VM_MEMORY="${VM_MEMORY:-2G}"
VM_DISK="${VM_DISK:-10G}"
VM_BASE_DIR="/home/ubuntu/github-runners"

# Verify Multipass CLI and daemon are available on the host before provisioning anything.
detect_runner_platform() {
  if ! command -v multipass >/dev/null 2>&1; then
    echo "Error: 'multipass' CLI is not installed on the host." >&2
    exit 1
  fi

  echo "Host platform: $(uname -s) ($(uname -m))"
  echo "Multipass version:"
  multipass version
}

# Launch a clean Ubuntu LTS VM (no host mounts), download the Linux runner archive via host, and extract 1..N copies inside the VM.
prepare_runner_session() {
  local repo="$1"
  local runner_count="$2"

  # Naming with 'session-<timestamp>' (never 'primary') guarantees Multipass mounts zero host directories.
  SESSION_NAME="session-$(date +%s)"
  CREATED_VM="$SESSION_NAME"

  echo "Launching isolated Multipass Ubuntu VM: $CREATED_VM (image: $VM_IMAGE, cpus: $VM_CPUS, memory: $VM_MEMORY, disk: $VM_DISK)..."
  multipass launch "$VM_IMAGE" \
    --name "$CREATED_VM" \
    --cpus "$VM_CPUS" \
    --memory "$VM_MEMORY" \
    --disk "$VM_DISK"

  # Detect CPU architecture inside the Linux VM so arm64 (Apple Silicon) and x86_64 hosts both pull the matching Linux runner.
  local vm_arch
  vm_arch=$(multipass exec -n "$CREATED_VM" -- uname -m | tr -d '\r')
  case "$vm_arch" in
    arm64|aarch64) RUNNER_ARCH="arm64" ;;
    x86_64)        RUNNER_ARCH="x64" ;;
    *) echo "Unsupported VM architecture: $vm_arch" >&2; exit 1 ;;
  esac

  echo "VM OS/Arch: linux/$RUNNER_ARCH"

  # Resolve latest actions/runner release using host GitHub CLI auth and stage tarball temporarily on host.
  local runner_version package download_url
  runner_version=$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | sed 's/^v//')
  package="actions-runner-${RUNNER_OS}-${RUNNER_ARCH}-${runner_version}.tar.gz"
  download_url="https://github.com/actions/runner/releases/download/v${runner_version}/${package}"

  echo "Runner version: $runner_version"
  echo "Runner package: $package"
  echo "Provisioning $runner_count runner(s) inside VM '$CREATED_VM'"

  HOST_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-runner-${SESSION_NAME}.XXXXXX")"
  echo "Downloading $package on host..."
  curl -fL "$download_url" -o "$HOST_STAGE_DIR/$package"

  # Transfer archive into the VM once, remove host staging copy immediately, and unpack 1..N runner folders in the VM.
  multipass exec -n "$CREATED_VM" -- mkdir -p "$VM_BASE_DIR"
  echo "Transferring $package into VM '$CREATED_VM'..."
  multipass transfer "$HOST_STAGE_DIR/$package" "$CREATED_VM:$VM_BASE_DIR/$package"
  rm -rf "$HOST_STAGE_DIR"
  HOST_STAGE_DIR=""

  local i vm_runner_dir
  for ((i=1; i<=runner_count; i++)); do
    vm_runner_dir="$VM_BASE_DIR/local-runner-$i"
    echo "Extracting local-runner-$i inside VM..."
    multipass exec -n "$CREATED_VM" -- bash -c "mkdir -p '$vm_runner_dir' && tar -xzf '$VM_BASE_DIR/$package' -C '$vm_runner_dir'"
  done

  echo "Runner software prepared inside VM '$CREATED_VM' at: $VM_BASE_DIR"
}

# Mint short-lived registration tokens on the host and register 1..N runner instances inside the VM.
register_runners() {
  local repo="$1"
  local runner_count="$2"
  local i vm_runner_dir runner_name token

  # Do NOT pass --ephemeral so runners remain alive across multi-job workflows until session teardown.
  for ((i=1; i<=runner_count; i++)); do
    vm_runner_dir="$VM_BASE_DIR/local-runner-$i"
    runner_name="$SESSION_NAME-runner-$i"

    token=$(gh api --method POST "repos/$repo/actions/runners/registration-token" --jq '.token')

    echo "Registering $runner_name inside VM '$CREATED_VM'..."
    multipass exec -n "$CREATED_VM" -- bash -c "
      cd '$vm_runner_dir' &&
      ./config.sh \
        --url 'https://github.com/$repo' \
        --token '$token' \
        --name '$runner_name' \
        --labels 'local-ci,$SESSION_NAME' \
        --work '_work' \
        --unattended
    "

    REGISTERED_RUNNERS+=("$runner_name:$vm_runner_dir")
    unset token
  done
}

# Start each registered runner agent in the background inside the VM with detached stdio.
start_runners() {
  local runner_count="$1"
  local i vm_runner_dir vm_pid

  for ((i=1; i<=runner_count; i++)); do
    vm_runner_dir="$VM_BASE_DIR/local-runner-$i"
    echo "Starting local-runner-$i inside VM '$CREATED_VM'..."

    # Redirect stdin/stdout/stderr away from multipass exec so the SSH/exec channel returns immediately.
    vm_pid=$(multipass exec -n "$CREATED_VM" -- bash -c "
      cd '$vm_runner_dir' &&
      nohup ./run.sh > runner.log 2>&1 < /dev/null &
      echo \$! | tee runner.pid
    " | tr -d '\r')

    STARTED_RUNNER_PIDS+=("$vm_pid")
  done

  echo "All VM runner processes launched (inspect VM live via: multipass shell $CREATED_VM)."
}

# Poll GitHub Actions API on the host until all session runners report online and idle.
wait_for_runners_online() {
  local repo="$1"
  local runner_count="$2"
  local attempt online_count=0

  for ((attempt=1; attempt<=30; attempt++)); do
    online_count=$(gh api "repos/$repo/actions/runners" \
      --paginate \
      --jq "[.runners[] |
        select(.name | startswith(\"$SESSION_NAME-runner-\")) |
        select(.status == \"online\" and .busy == false)] |
        length" | awk '{sum += $1} END {print sum+0}')

    echo "Runners ready: $online_count/$runner_count"

    if [[ "$online_count" -eq "$runner_count" ]]; then
      echo "All runners are ready!"
      return 0
    fi

    sleep 2
  done

  echo "Runner readiness check timed out." >&2
  return 1
}

# Report whether this session allocated any VM, host staging folder, or runner registrations requiring cleanup.
has_session_resources() {
  [[ -n "$CREATED_VM" || -n "$HOST_STAGE_DIR" || ${#STARTED_RUNNER_PIDS[@]} -gt 0 || ${#REGISTERED_RUNNERS[@]} -gt 0 ]]
}

# Gracefully stop runner processes inside the VM before deregistering.
stop_all_runners() {
  if [[ -z "$CREATED_VM" || ${#STARTED_RUNNER_PIDS[@]} -eq 0 ]]; then
    return 0
  fi

  local pid
  for pid in "${STARTED_RUNNER_PIDS[@]}"; do
    echo "Stopping VM runner process (PID: $pid)..."
    multipass exec -n "$CREATED_VM" -- bash -c "
      if kill -0 '$pid' 2>/dev/null; then
        kill -TERM '$pid' 2>/dev/null || true
        for _ in {1..10}; do
          kill -0 '$pid' 2>/dev/null || break
          sleep 0.5
        done
        kill -KILL '$pid' 2>/dev/null || true
      fi
    " 2>/dev/null || true
  done
}

# Deregister all VM runners from GitHub (via config.sh inside VM, falling back to GitHub REST API removal if VM is unreachable).
deregister_all_runners() {
  local repo="${1:-$REPO}"

  if [[ ${#REGISTERED_RUNNERS[@]} -eq 0 ]]; then
    return 0
  fi

  local entry runner_name vm_runner_dir remove_token runner_id
  for entry in "${REGISTERED_RUNNERS[@]}"; do
    runner_name="${entry%%:*}"
    vm_runner_dir="${entry#*:}"

    echo "Deregistering $runner_name..."
    remove_token=$(gh api --method POST "repos/$repo/actions/runners/remove-token" --jq '.token' 2>/dev/null) || remove_token=""

    if [[ -n "$remove_token" && -n "$CREATED_VM" ]] && \
       multipass exec -n "$CREATED_VM" -- bash -c "[[ ! -f '$vm_runner_dir/.runner' ]] || (cd '$vm_runner_dir' && ./config.sh remove --token '$remove_token')" 2>/dev/null; then
      unset remove_token
      continue
    fi
    unset remove_token

    # Fallback: delete runner directly via GitHub API if the VM stopped or config.sh remove failed.
    runner_id=$(gh api "repos/$repo/actions/runners" --paginate --jq ".runners[] | select(.name == \"$runner_name\") | .id" 2>/dev/null | head -n 1)
    if [[ -n "$runner_id" ]]; then
      gh api --method DELETE "repos/$repo/actions/runners/$runner_id" >/dev/null 2>&1 || \
        echo "Warning: Failed to delete runner $runner_name (id: $runner_id) via API." >&2
    fi
  done
}

# Delete temporary host staging files and purge the Multipass VM completely.
finalize_runner_environment() {
  if [[ -n "$HOST_STAGE_DIR" && -d "$HOST_STAGE_DIR" ]]; then
    rm -rf "$HOST_STAGE_DIR"
  fi

  if [[ -n "$CREATED_VM" ]]; then
    echo "Deleting and purging Multipass VM '$CREATED_VM'..."
    multipass delete --purge "$CREATED_VM" 2>/dev/null || \
      echo "Warning: Multipass VM '$CREATED_VM' could not be purged (it may not have finished launching)." >&2
  fi
}
