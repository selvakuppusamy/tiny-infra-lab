#!/bin/bash
# Orchestrates ephemeral local GitHub Actions runners, workflow dispatch, live run monitoring, and guaranteed teardown.

# Fail fast on command errors, unset variables, or broken pipes during normal execution.
set -euo pipefail

# Resolve this script's directory so helper libraries load reliably regardless of caller working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Target repository, workflow filename (must exist on default branch), and branch under test.
REPO="${REPO:-selvakuppusamy/tiny-infra-lab}"
WORKFLOW="${WORKFLOW:-01-self-hosted-runner-check.yaml}"
BRANCH="${BRANCH:-self-hosted-local-runner}"

# Number of concurrent local runner instances to provision (defaults to 1).
RUNNER_COUNT="${1:-1}"

# Load runner lifecycle and workflow dispatch helper modules.
source "$SCRIPT_DIR/lib/runner.sh"
source "$SCRIPT_DIR/lib/workflow.sh"

# Tear down all started runner processes and GitHub registrations on any exit while preserving the original exit code.
cleanup() {
  local exit_code=$?

  # Disarm traps and disable strict mode so one failed teardown step never blocks remaining runners.
  trap - EXIT INT TERM
  set +eu

  # Run runner teardown if this session started processes or registered any runner instances.
  if [[ ${#STARTED_RUNNER_PIDS[@]} -gt 0 || ${#REGISTERED_RUNNERS[@]} -gt 0 ]]; then
    echo "Tearing down session runners (preserving exit code: $exit_code)..."
    stop_all_runners
    deregister_all_runners "$REPO"
    # Future hook: Multipass VM teardown (e.g. destroy_all_vms) slots in here.
    echo "Teardown finished."
  fi

  # Keep session directory intact so runner.log and _diag/pages/*.log stay available for debugging.
  if [[ -n "${SESSION_DIR:-}" && -d "$SESSION_DIR" ]]; then
    echo "Diagnostic logs retained at: $SESSION_DIR"
  fi

  exit "$exit_code"
}

# Route Ctrl+C (SIGINT) and termination (SIGTERM) into standard exit codes so the EXIT trap runs once.
handle_signal() {
  local signal_exit_code="$1"
  echo "Interrupt received; initiating runner teardown..." >&2
  exit "$signal_exit_code"
}

# Register exit and signal traps before creating any stateful directories, processes, or GitHub registrations.
trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

# Validate that the requested runner count is a positive integer (>= 1).
if ! [[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Runner count must be a positive integer." >&2
  exit 1
fi

# Verify GitHub CLI authentication before downloading or registering anything.
gh auth status

# Provision, register, start, and verify readiness of local self-hosted runners.
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
