#!/bin/bash
# Orchestrates disposable local GitHub Actions runners (inside an isolated Multipass VM or on host),
# workflow dispatch, live run monitoring, and guaranteed teardown.

# Fail fast on command errors, unset variables, or broken pipes during normal execution.
set -euo pipefail

# Resolve this script's directory so helper libraries load reliably regardless of caller working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Target repository, workflow filename (must exist on default branch), branch under test, and runner backend ('vm' or 'host').
REPO="${REPO:-selvakuppusamy/tiny-infra-lab}"
WORKFLOW="${WORKFLOW:-01-self-hosted-runner-check.yaml}"
BRANCH="${BRANCH:-self-hosted-local-runner}"
RUNNER_MODE="${RUNNER_MODE:-vm}"

# Number of concurrent local runner instances to provision (defaults to 1).
RUNNER_COUNT="${1:-1}"

# Validate requested runner mode and load the matching runner backend + workflow dispatch module.
case "$RUNNER_MODE" in
  vm)
    source "$SCRIPT_DIR/lib/multipass.sh"
    ;;
  host)
    source "$SCRIPT_DIR/lib/runner.sh"
    ;;
  *)
    echo "Runner mode must be 'vm' or 'host' (got: '$RUNNER_MODE')." >&2
    exit 1
    ;;
esac
source "$SCRIPT_DIR/lib/workflow.sh"

# Tear down all started runner processes, GitHub registrations, and disposable VMs on any exit while preserving the original exit code.
cleanup() {
  local exit_code=$?

  # Disarm traps and disable strict mode so one failed teardown step never blocks remaining cleanup.
  trap - EXIT INT TERM
  set +eu

  if has_session_resources; then
    echo "Tearing down session resources (mode: $RUNNER_MODE, preserving exit code: $exit_code)..."
    stop_all_runners
    deregister_all_runners "$REPO"
    finalize_runner_environment
    echo "Teardown finished."
  else
    finalize_runner_environment
  fi

  exit "$exit_code"
}

# Route Ctrl+C (SIGINT) and termination (SIGTERM) into standard exit codes so the EXIT trap runs once.
handle_signal() {
  local signal_exit_code="$1"
  echo "Interrupt received; initiating runner teardown..." >&2
  exit "$signal_exit_code"
}

# Register exit and signal traps before creating any VMs, directories, processes, or GitHub registrations.
trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

# Validate that the requested runner count is a positive integer (>= 1).
if ! [[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Runner count must be a positive integer." >&2
  exit 1
fi

echo "Selected runner mode: $RUNNER_MODE"

# Verify GitHub CLI authentication before downloading, launching VMs, or registering anything.
gh auth status

# Provision, register, start, and verify readiness of local self-hosted runners (VM or host).
detect_runner_platform
prepare_runner_session "$REPO" "$RUNNER_COUNT"
register_runners "$REPO" "$RUNNER_COUNT"
start_runners "$RUNNER_COUNT"
wait_for_runners_online "$REPO" "$RUNNER_COUNT"

# Record UTC timestamp before dispatch so run lookup ignores older runs on the same branch.
DISPATCHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Trigger the workflow bound to this session's unique runner label, locate the run, and stream status until completion.
dispatch_workflow "$REPO" "$WORKFLOW" "$BRANCH" "$SESSION_NAME"
RUN_ID=$(wait_for_run_id "$REPO" "$WORKFLOW" "$BRANCH" "$DISPATCHED_AT")
watch_workflow_run "$REPO" "$RUN_ID"
