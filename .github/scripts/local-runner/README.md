# Local Ephemeral GitHub Actions Runner (`local-runner`)

Provisions disposable self-hosted GitHub Actions runners on a local machine, dispatches a target workflow bound exclusively to that session, streams run status live, and guarantees runner teardown on exit.

## Architecture

```text
.github/scripts/local-runner/
├── provision-runner.sh   # Entrypoint: config, trap cleanup (EXIT/INT/TERM), orchestration
└── lib/
    ├── runner.sh         # OS/arch detection, download, register, start, readiness, stop & deregister
    └── workflow.sh       # workflow_dispatch (-f runner_label), timestamped run lookup, gh run watch
```

*(Designed so future VM providers such as Multipass Ubuntu can plug in alongside `lib/runner.sh` without changing workflow dispatch logic.)*

## Prerequisites

- GitHub CLI authenticated (`gh auth status`) with repository admin/runner registration permissions on `selvakuppusamy/tiny-infra-lab`.
- Workflow file registered on `main` and any workflow/branch changes committed and pushed to the target remote branch (`BRANCH`) before dispatching.
- Local cluster/container tools running on the host when testing local infra workflows (`docker`, `kubectl`, `helm`, `minikube`).

## Usage

```bash
# Provision 1 local runner (default) and trigger 01-self-hosted-runner-check.yaml on self-hosted-local-runner
./.github/scripts/local-runner/provision-runner.sh

# Provision N concurrent local runners
./.github/scripts/local-runner/provision-runner.sh 2

# Override target workflow or branch without editing the script
WORKFLOW="02-build-local-deploy-local.yml" BRANCH="main" ./.github/scripts/local-runner/provision-runner.sh
```

## Opting Any Workflow Into `local-runner` (One-Time Hook)

Add an optional `runner_label` input with a fallback so manual UI runs still target `self-hosted` (or `ubuntu-latest`) when `runner_label` is left empty:

```yaml
on:
  workflow_dispatch:
    inputs:
      runner_label:
        description: 'Optional custom runner label (leave empty for default self-hosted runner)'
        required: false
        default: ''
        type: string

jobs:
  check-runner:
    runs-on: ${{ github.event.inputs.runner_label || 'self-hosted' }}
```

## Live Local Debugging

Session files and logs are retained after teardown at `~/github-runners/session-<timestamp>/`:

- **Runner stdout / startup log:** `tail -f ~/github-runners/session-*/local-runner-1/runner.log`
- **Runner daemon / worker logs:** `tail -f ~/github-runners/session-*/local-runner-1/_diag/*.log`
- **Live step stdout/stderr:** `tail -f "$(ls -t ~/github-runners/session-*/local-runner-1/_diag/pages/*.log | head -1)"`
- **Checked-out workspace:** `ls -la ~/github-runners/session-*/local-runner-1/_work/tiny-infra-lab/tiny-infra-lab/`

## Key Reliability Safeguards

| # | Failure Mode Prevented | Mechanism |
| :-: | :--- | :--- |
| **1** | `HTTP 404` from URL-encoded `./.github/workflows/...` paths | Uses bare workflow filename (`WORKFLOW="01-self-hosted-runner-check.yaml"`). |
| **2** | Early failure or `Ctrl+C` leaving orphaned runners on host and GitHub | Registers `trap cleanup EXIT` (+ `INT`/`TERM` forwarding) with independent `REGISTERED_RUNNERS` and `STARTED_RUNNER_PIDS` tracking. |
| **3** | Single failed deregistration aborting cleanup of remaining runners | Disables `errexit`/`nounset` (`set +eu`) inside `cleanup()` and waits gracefully (`SIGTERM` → 5s poll → `SIGKILL`) before `./config.sh remove`. |
| **4** | `gh run list --limit 1` matching a stale workflow run on the same branch | Records UTC `DISPATCHED_AT` timestamp before `gh workflow run` and filters `createdAt >= $DISPATCHED_AT`. |
| **5** | Static `runs-on: self-hosted` colliding with other persistent or concurrent runners | Registers runners with `--labels "local-ci,$SESSION_NAME"` and binds the dispatched run via `-f runner_label="$SESSION_NAME"`. |
