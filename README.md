# Tiny Infra Lab

A small, reusable infrastructure playground for experimenting with deployment, containers, CI/CD boundaries, authentication, and infrastructure tooling.

The goal is to keep the base setup minimal and known-good so it can be extended or forked whenever a new idea needs proving.

---

## Current Setup

```text
Node app
→ Docker image
→ GitHub Actions
→ GHCR
→ self-hosted runner
→ Helm
→ Minikube / Kubernetes
→ Service
→ health check
```

The repo currently demonstrates:

- local Docker build and run
- self-hosted GitHub Actions runner
- pushing images to GHCR
- pulling images from GHCR
- loading images into Minikube
- Kubernetes pulling directly from a private registry
- `imagePullSecrets`
- Helm deployment
- Kubernetes Service
- Ingress experiment
- port-forwarding
- rollout and health verification

---

## Workflows

```text
01-self-hosted-runner-check.yaml
→ prove the local runner and tooling are available

02-build-local-deploy-local.yml
→ build locally on self-hosted runner and deploy to Minikube

03-push-image-to-ghcr.yml
→ build and push image to GHCR

04-pull-ghrc-image-deploy-local.yml
→ pull remote image through the runner and deploy locally

05-ghcr-image-directly-pulled-by-k8s.yml
→ Kubernetes authenticates to GHCR and pulls the image directly

06-minikube-check-in-ci-runner.yml
→ check Colima, Docker, and Minikube in three independent Ubuntu jobs
```

### Minikube Check in CI Runner

After the workflow is merged into the default branch, open **Actions → Minikube
Check in CI Runner → Run workflow**. It is manual-only and uses `ubuntu-latest`;
your MacBook does not need to be online.

The workflow has three independent jobs, each on its own fresh Ubuntu runner:

- **Colima:** use the preinstalled Homebrew to install Colima and QEMU, grant
  access to `/dev/kvm`, start Colima, and print its status and Docker context.
  Homebrew installs Colima's Lima dependency automatically.
- **Docker:** start the preinstalled Docker engine and print its service status,
  version, contexts, and engine information.
- **Minikube:** use the preinstalled Docker and Minikube, start a cluster with the
  Docker driver, and print `minikube status`.

There are no Homebrew availability checks or fallback installers. The workflow
relies on the tools included in the [GitHub Ubuntu runner image](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md).
The Colima job also requires `/dev/kvm` for its VM.

Jobs do not share their Docker engines or clusters: Minikube uses its own
runner's Docker engine, not the Colima VM from the other job. GitHub discards
all three runners after the jobs finish. Add experiment steps to the relevant
job to use its environment during that run.

---

## Purpose

Use this repo whenever an infrastructure idea needs a small environment to prove it first.

Possible future experiments:

```text
Terraform
Pulumi
cloud Kubernetes
cloud storage
Kubernetes Secrets
different registries
different CI platforms
different orchestrators
networking
Ingress
monitoring
Jobs / CronJobs
```

Keep the base simple.

If an experiment becomes large, fork this repo, prove the idea there, and retire the fork when it is no longer useful.

---

## Boundary Questions

When experimenting, always ask:

```text
Who is authenticating?
To what?
Where does the credential live?
How does it cross the boundary?
What survives after the process dies?
```

---

## Local Access

For the current Minikube setup:

```bash
kubectl port-forward service/tiny-app 3000:80
```

Then:

```bash
curl http://localhost:3000/health
```

Port forwarding exists only while the `kubectl` command is running.
