#!/bin/bash
# Manages local GitHub Actions runner package download, registration, process startup, readiness polling, and teardown.

# Session-scoped state arrays tracked independently so partial failures still clean up cleanly.
REGISTERED_RUNNERS=()
STARTED_RUNNER_PIDS=()
SESSION_DIR=""
SESSION_NAME=""
RUNNER_OS=""
RUNNER_ARCH=""

# Detect host OS and CPU architecture and map them to GitHub Actions runner release naming.
detect_runner_platform() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)

  echo "Operating system: $os"
  echo "Architecture: $arch"

  # Map host kernel name to GitHub's runner OS identifier.
  case "$os" in
    # macOS uses the 'osx' runner package prefix.
    Darwin)
      RUNNER_OS="osx"
      ;;
    # Linux uses the 'linux' runner package prefix.
    Linux)
      RUNNER_OS="linux"
      ;;
    # Native Windows shells are unsupported; direct callers to an Ubuntu VM.
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      echo "Native Windows provisioning is not supported yet. Please execute inside an Ubuntu VM." >&2
      exit 1
      ;;
    # Reject any unrecognised operating system.
    *)
      echo "Unsupported OS: $os" >&2
      exit 1
      ;;
  esac

  # Map host CPU architecture to GitHub's runner architecture identifier.
  case "$arch" in
    # Apple Silicon and 64-bit ARM Linux map to arm64.
    arm64|aarch64) RUNNER_ARCH="arm64" ;;
    # 64-bit Intel/AMD platforms map to x64.
    x86_64)        RUNNER_ARCH="x64" ;;
    # Reject unsupported CPU architectures.
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac
}

# Create a timestamped session folder, download the runner archive once, and extract N runner directories.
prepare_runner_session() {
  local repo="$1"
  local runner_count="$2"

  # Query GitHub API for the latest actions/runner release tag without the leading 'v'.
  local runner_version package download_url
  runner_version=$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | sed 's/^v//')
  package="actions-runner-${RUNNER_OS}-${RUNNER_ARCH}-${runner_version}.tar.gz"

  echo "Runner version: $runner_version"
  echo "Runner package: $package"
  echo "Provisioning $runner_count runner(s)"

  # Isolate binaries, _work folders, and _diag logs under a unique session directory.
  SESSION_DIR="$HOME/github-runners/session-$(date +%s)"
  SESSION_NAME="$(basename "$SESSION_DIR")"
  mkdir -p "$SESSION_DIR"

  # Download the runner tarball once and extract into each runner's isolated directory.
  download_url="https://github.com/actions/runner/releases/download/v${runner_version}/${package}"
  echo "Downloading $package..."
  curl -fL "$download_url" -o "$SESSION_DIR/$package"

  # Unpack a dedicated copy for each runner instance.
  local i runner_dir
  for ((i=1; i<=runner_count; i++)); do
    runner_dir="$SESSION_DIR/local-runner-$i"
    mkdir -p "$runner_dir"
    echo "Extracting local-runner-$i..."
    tar -xzf "$SESSION_DIR/$package" -C "$runner_dir"
  done

  echo "Runner software prepared at: $SESSION_DIR"
}

# Register each extracted runner instance against the target GitHub repository.
register_runners() {
  local repo="$1"
  local runner_count="$2"
  local i runner_dir runner_name token

  # Register runners one by one and record each directory immediately upon success.
  for ((i=1; i<=runner_count; i++)); do
    runner_dir="$SESSION_DIR/local-runner-$i"
    runner_name="$SESSION_NAME-runner-$i"

    # Request a short-lived registration token from GitHub for this runner.
    token=$(gh api --method POST "repos/$repo/actions/runners/registration-token" --jq '.token')

    echo "Registering $runner_name..."

    # Run config.sh in a subshell with both a group tag (local-ci) and a unique session label ($SESSION_NAME).
    (
      cd "$runner_dir"
      ./config.sh \
        --url "https://github.com/$repo" \
        --token "$token" \
        --name "$runner_name" \
        --labels "local-ci,$SESSION_NAME" \
        --work "_work" \
        --unattended
    )

    # Track this registered runner immediately so cleanup deregisters it if runner i+1 fails.
    REGISTERED_RUNNERS+=("$runner_dir")
    unset token
  done
}

# Launch each registered runner agent in the background and track its PID.
start_runners() {
  local runner_count="$1"
  local i runner_dir runner_pid

  # Start each runner via exec so $! points directly to the live run.sh process.
  for ((i=1; i<=runner_count; i++)); do
    runner_dir="$SESSION_DIR/local-runner-$i"
    echo "Starting local-runner-$i..."

    (cd "$runner_dir" && exec ./run.sh) > "$runner_dir/runner.log" 2>&1 &
    runner_pid=$!
    echo "$runner_pid" > "$runner_dir/runner.pid"

    # Track the started PID immediately so cleanup stops it before deregistering.
    STARTED_RUNNER_PIDS+=("$runner_pid")
  done

  echo "All runner processes launched."
}

# Poll GitHub Actions API until all session runners report online and idle.
wait_for_runners_online() {
  local repo="$1"
  local runner_count="$2"
  local attempt online_count=0

  # Poll every 2 seconds (up to 60 seconds total) for all runners in this session.
  for ((attempt=1; attempt<=30; attempt++)); do
    online_count=$(gh api "repos/$repo/actions/runners" \
      --paginate \
      --jq "[.runners[] |
        select(.name | startswith(\"$SESSION_NAME-runner-\")) |
        select(.status == \"online\" and .busy == false)] |
        length" | awk '{sum += $1} END {print sum+0}')

    echo "Runners ready: $online_count/$runner_count"

    # Return cleanly as soon as every provisioned runner is online.
    if [[ "$online_count" -eq "$runner_count" ]]; then
      echo "All runners are ready!"
      return 0
    fi

    sleep 2
  done

  # Fail (triggering trap cleanup) if readiness timed out.
  echo "Runner readiness check timed out." >&2
  return 1
}

# Gracefully stop every background runner process tracked in this session.
stop_all_runners() {
  # Guard empty array expansion for macOS Bash 3.2 compatibility.
  if [[ ${#STARTED_RUNNER_PIDS[@]} -eq 0 ]]; then
    return 0
  fi

  local pid wait_step
  for pid in "${STARTED_RUNNER_PIDS[@]}"; do
    # Skip if the runner process has already exited.
    if ! kill -0 "$pid" 2>/dev/null; then
      continue
    fi

    # Send SIGTERM so Runner.Listener flushes _diag logs cleanly.
    echo "Stopping runner process (PID: $pid)..."
    kill -TERM "$pid" 2>/dev/null || true

    # Wait up to 5 seconds for clean shutdown before deregistration runs.
    for ((wait_step=1; wait_step<=10; wait_step++)); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.5
    done

    # Force-kill only if the process is still alive past the graceful window.
    if kill -0 "$pid" 2>/dev/null; then
      echo "Process $pid did not exit gracefully; sending SIGKILL..." >&2
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}

# Deregister every configured runner directory tracked in this session without aborting on single failures.
deregister_all_runners() {
  local repo="${1:-$REPO}"

  # Guard empty array expansion for macOS Bash 3.2 compatibility.
  if [[ ${#REGISTERED_RUNNERS[@]} -eq 0 ]]; then
    return 0
  fi

  local runner_dir runner_name remove_token
  for runner_dir in "${REGISTERED_RUNNERS[@]}"; do
    runner_name="$(basename "$runner_dir")"

    # Skip if the .runner registration state file is absent.
    if [[ ! -f "$runner_dir/.runner" ]]; then
      continue
    fi

    # Fetch a removal token; warn and continue to remaining runners if token request fails.
    remove_token=$(gh api --method POST "repos/$repo/actions/runners/remove-token" --jq '.token' 2>/dev/null) || remove_token=""
    if [[ -z "$remove_token" ]]; then
      echo "Warning: Could not obtain removal token for $runner_name; continuing cleanup." >&2
      continue
    fi

    # Deregister the runner in a subshell; warn and continue if removal fails.
    echo "Deregistering $runner_name..."
    if ! (cd "$runner_dir" && ./config.sh remove --token "$remove_token"); then
      echo "Warning: Failed to deregister $runner_name; continuing cleanup." >&2
    fi
    unset remove_token
  done
}
