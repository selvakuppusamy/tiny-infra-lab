# Local Disposable GitHub Actions Runner (`local-runner`)

Provisions session-scoped self-hosted GitHub Actions runners — either inside an **isolated Multipass Ubuntu LTS VM** (`RUNNER_MODE=vm`, default) or directly on the **host machine** (`RUNNER_MODE=host`) — dispatches a target workflow bound exclusively to that session, streams run status live, and guarantees teardown on exit.

## Architecture

```text
.github/scripts/local-runner/
├── provision-runner.sh   # Entrypoint: RUNNER_MODE (vm|host), trap cleanup (EXIT/INT/TERM), orchestration
└── lib/
    ├── multipass.sh      # VM mode: launch unmounted Ubuntu LTS VM, stage & register 1..N runners in VM, deregister + purge VM
    ├── runner.sh         # Host mode: OS/arch detection, download, register, start, stop & deregister on host
    └── workflow.sh       # workflow_dispatch (-f runner_label), timestamped run lookup, gh run watch
```

## Security & Isolation Boundary (`RUNNER_MODE=vm`)

- **Zero host filesystem access:** Launches a named Multipass instance (`session-<timestamp>`, never `primary`) without `--mount`, so host drives, `$HOME`, `~/.gitconfig`, `~/.ssh`, and `~/.config/gh` do not exist inside the VM.
- **Host-only GitHub CLI credentials:** `gh` runs only on the host Mac. The host mints a single-use runner registration token and passes only that token into `multipass exec` to configure the runner.
- **Workflow-scoped persistence (not single-job `--ephemeral`):** Runners stay online inside the VM across sequential jobs in the dispatched workflow, then deregister and `multipass delete --purge` wipes the VM disk when `gh run watch` completes (while all job/step logs remain in the GitHub Actions browser UI).

## Prerequisites

- GitHub CLI authenticated on host (`gh auth status`) with repository runner registration permissions on `selvakuppusamy/tiny-infra-lab`.
- For `RUNNER_MODE=vm` (default): [Multipass](https://multipass.run/) installed and running on the host (`multipass version`).
- Target workflow file registered on `main`, and changes pushed to the remote `BRANCH` before dispatching.

## Usage

```bash
# Default (RUNNER_MODE=vm): Launch 1 Ubuntu LTS VM with 1 runner and run 01-self-hosted-runner-check.yaml
./.github/scripts/local-runner/provision-runner.sh

# Launch 1 Ubuntu LTS VM hosting 2 concurrent runner agents
./.github/scripts/local-runner/provision-runner.sh 2

# Customize VM sizing if a workflow needs more resources
VM_CPUS=4 VM_MEMORY=4G VM_DISK=20G ./.github/scripts/local-runner/provision-runner.sh

# Run directly on the host machine instead of a Multipass VM
RUNNER_MODE=host ./.github/scripts/local-runner/provision-runner.sh
```

## Inspecting a Live VM During a Workflow Run

While the workflow job is running (e.g. during the 60s inspection pause in `01-self-hosted-runner-check.yaml`), open another terminal on your host:

```bash
# List active VM and verify state/IP
multipass list

# Open an interactive shell inside the running VM (check mounts, env, processes, _work)
multipass shell session-<timestamp>
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
