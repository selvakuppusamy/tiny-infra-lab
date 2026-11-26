#!/bin/bash
# Handles GitHub Actions workflow_dispatch triggering, run discovery, and live run status watching.

# Trigger a workflow_dispatch event bound to this session's unique runner label.
dispatch_workflow() {
  local repo="$1"
  local workflow="$2"
  local branch="$3"
  local runner_label="$4"

  echo "Triggering workflow: $workflow (branch: $branch, runner_label: $runner_label)"

  # Pass --ref (branch workflow YAML & checkout ref) and -f runner_label (session isolation).
  gh workflow run "$workflow" \
    --repo "$repo" \
    --ref "$branch" \
    -f runner_label="$runner_label"
}

# Poll GitHub Actions for the newly created workflow_dispatch run ID and print it to stdout.
wait_for_run_id() {
  local repo="$1"
  local workflow="$2"
  local branch="$3"
  local dispatched_at="$4"
  local attempt run_id=""

  # Send progress logs to stderr so stdout only emits the resolved numeric run ID.
  echo "Waiting for workflow run to appear..." >&2

  # Poll up to 15 times (30 seconds) for a workflow_dispatch run created at or after dispatch time.
  for ((attempt=1; attempt<=15; attempt++)); do
    run_id=$(gh run list \
      --repo "$repo" \
      --workflow "$workflow" \
      --branch "$branch" \
      --event workflow_dispatch \
      --limit 5 \
      --json databaseId,createdAt \
      --jq "[.[] | select(.createdAt >= \"$dispatched_at\")][0].databaseId // empty")

    # Return the run ID as soon as GitHub indexes the new run.
    if [[ -n "$run_id" ]]; then
      echo "$run_id"
      return 0
    fi

    sleep 2
  done

  # Fail (triggering trap cleanup) if no matching workflow run appeared in time.
  echo "Could not identify workflow run." >&2
  return 1
}

# Watch the workflow run live until completion and return the workflow's exit code.
watch_workflow_run() {
  local repo="$1"
  local run_id="$2"
  local workflow_exit_code=0

  echo "Monitoring workflow run: $run_id"

  # Capture non-zero workflow status cleanly and return it so trap cleanup preserves it.
  gh run watch "$run_id" \
    --repo "$repo" \
    --exit-status || workflow_exit_code=$?

  return "$workflow_exit_code"
}
