<p align="center">
  <img src="https://raw.githubusercontent.com/blackoutsecure/docker-github-runner/main/logo.png" alt="github logo" width="200">
</p>

# docker-github-runner

[![GitHub Stars](https://img.shields.io/github/stars/blackoutsecure/docker-github-runner.svg?style=flat-square)](https://github.com/blackoutsecure/docker-github-runner/stargazers)
[![Docker Pulls](https://img.shields.io/docker/pulls/blackoutsecure/github-runner.svg?style=flat-square)](https://hub.docker.com/r/blackoutsecure/github-runner)
[![GitHub Release](https://img.shields.io/github/release/blackoutsecure/docker-github-runner.svg?style=flat-square)](https://github.com/blackoutsecure/docker-github-runner/releases)
[![Blackout Secure Launchpad](https://img.shields.io/github/actions/workflow/status/blackoutsecure/docker-github-runner/bos-launchpad.yml?style=flat-square&label=blackout%20secure%20launchpad&color=E7931D)](https://github.com/blackoutsecure/docker-github-runner/actions/workflows/bos-launchpad.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)

Unofficial community container image for the [GitHub Actions Runner](https://github.com/actions/runner), built with s6-overlay supervision, hardened runtime defaults, multi-arch (amd64 / arm64) builds, and first-class Balena deployment support.

Sponsored and maintained by [Blackout Secure](https://blackoutsecure.app/).

> **Image & Listings**
> - **Docker Hub image:** [`blackoutsecure/github-runner`](https://hub.docker.com/r/blackoutsecure/github-runner)
> - **Balena Marketplace:** [github-runner](https://hub.balena.io/blocks/2362920/github-runner)
> - **GitHub repository:** [`blackoutsecure/docker-github-runner`](https://github.com/blackoutsecure/docker-github-runner)
>
> The image is *not* an official LinuxServer.io release.

---

## Table of Contents

- [docker-github-runner](#docker-github-runner)
  - [Table of Contents](#table-of-contents)
  - [Quick Start](#quick-start)
  - [Image Availability](#image-availability)
  - [Supported Architectures](#supported-architectures)
  - [Usage](#usage)
    - [Docker Compose (recommended)](#docker-compose-recommended)
    - [Ephemeral runners](#ephemeral-runners)
    - [Persistent runner with `/config` volume](#persistent-runner-with-config-volume)
    - [Recommended: Fixed pool of ephemeral runners](#recommended-fixed-pool-of-ephemeral-runners)
    - [Advanced: Dynamic scaling](#advanced-dynamic-scaling)
    - [Balena deployment](#balena-deployment)
    - [Docker CLI](#docker-cli)
  - [Parameters](#parameters)
    - [Environment variables](#environment-variables)
      - [Registration](#registration)
      - [Docker secrets (file-based credentials)](#docker-secrets-file-based-credentials)
      - [Job environment injection](#job-environment-injection)
      - [Docker-in-Docker](#docker-in-docker)
      - [Logging](#logging)
      - [Health / liveness](#health--liveness)
      - [Stale offline runner cleanup](#stale-offline-runner-cleanup)
      - [Custom packages / init script (escape hatch)](#custom-packages--init-script-escape-hatch)
      - [Process / shutdown](#process--shutdown)
    - [Autoscaler variables](#autoscaler-variables)
    - [Volumes](#volumes)
  - [Configuration](#configuration)
    - [Registration tokens](#registration-tokens)
    - [Using a GitHub PAT (recommended)](#using-a-github-pat-recommended)
    - [Using a GitHub App or repo secret (`GITHUB_TOKEN`)](#using-a-github-app-or-repo-secret-github_token)
    - [Using Docker secrets (`_FILE` variants)](#using-docker-secrets-_file-variants)
    - [Injecting custom env into jobs](#injecting-custom-env-into-jobs)
  - [Privileges required by feature](#privileges-required-by-feature)
    - [Minimum baseline](#minimum-baseline)
    - [Per-feature additions](#per-feature-additions)
    - [GitHub API endpoints by variable](#github-api-endpoints-by-variable)
    - [Minimum-token cookbook](#minimum-token-cookbook)
  - [User / Group Identifiers](#user--group-identifiers)
  - [Application setup notes](#application-setup-notes)
    - [Ephemeral mode and the concurrency model](#ephemeral-mode-and-the-concurrency-model)
    - [Docker-in-Docker (container-based jobs)](#docker-in-docker-container-based-jobs)
      - [`DOCKER_IN_DOCKER` + LSIO non-root (`--user`)](#docker_in_docker--lsio-non-root---user)
    - [Custom packages / init scripts](#custom-packages--init-scripts)
    - [Non-root mode (LSIO `--user`)](#non-root-mode-lsio---user)
  - [Stale offline runner cleanup](#stale-offline-runner-cleanup-1)
  - [Health monitoring](#health-monitoring)
    - [Docker `HEALTHCHECK`](#docker-healthcheck)
    - [Auto-recovery on disconnection](#auto-recovery-on-disconnection)
    - [s6 service supervision](#s6-service-supervision)
  - [Logging](#logging-1)
  - [Security considerations](#security-considerations)
  - [Troubleshooting](#troubleshooting)
    - [Container won't start](#container-wont-start)
    - [Runner appears offline in GitHub](#runner-appears-offline-in-github)
    - [Runner won't pick up jobs](#runner-wont-pick-up-jobs)
    - [Container shuts down before deregistering](#container-shuts-down-before-deregistering)
    - [Slow first-job latency (`Starting process...` takes a while)](#slow-first-job-latency-starting-process-takes-a-while)
  - [Release \& versioning](#release--versioning)
  - [Support](#support)
  - [References](#references)
  - [License](#license)

---

## Quick Start

```bash
docker run -d \
  --name=gh-runner \
  --restart unless-stopped \
  -e TZ=Etc/UTC \
  -e RUNNER_URL=https://github.com/OWNER/REPO \
  -e RUNNER_TOKEN=YOUR_REGISTRATION_TOKEN \
  -v runner-config:/config \
  --security-opt no-new-privileges:true \
  blackoutsecure/github-runner:latest
```

Then `docker logs gh-runner` should show a startup banner ending with `Listening for Jobs`.

For compose, ephemeral, hardened, fixed-pool, and dynamic-scaling configurations, see [Usage](#usage).

## Image Availability

- Docker Hub: [`blackoutsecure/github-runner`](https://hub.docker.com/r/blackoutsecure/github-runner)
- Multi-arch manifests (`linux/amd64` + `linux/arm64`) — Docker selects the right architecture automatically.

```bash
docker pull blackoutsecure/github-runner:latest        # rolling latest
docker pull blackoutsecure/github-runner:2.333.1       # pinned upstream runner version
docker pull blackoutsecure/github-runner:sha-<commit>  # pinned source revision
```

| Tag | Meaning |
| --- | --- |
| `latest` | Latest release on top of Ubuntu 24.04 Noble; multi-arch |
| `<runner-version>` (e.g. `2.333.1`) | Pinned upstream actions/runner release |
| `sha-<commit>` | Pinned to a specific commit of this repository |
| `amd64-latest` / `arm64v8-latest` | Architecture-specific aliases for `latest` |

For production, pin to a `<runner-version>` or `sha-<commit>` tag and update on a schedule.

## Supported Architectures

| Architecture | Platform | Alias tag |
| --- | --- | --- |
| x86-64 | `linux/amd64` | `amd64-latest` |
| ARM 64-bit | `linux/arm64` | `arm64v8-latest` |

## Usage

### Docker Compose (recommended)

A minimal, secure starting point — persistent runner with a `/config` volume:

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    container_name: gh-runner
    environment:
      - TZ=Etc/UTC
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx                  # or RUNNER_TOKEN=ghr_xxx
      - RUNNER_NAME=my-runner               # optional; defaults to container hostname
      # - RUNNER_LABELS=self-hosted,linux,x64
    volumes:
      - /path/to/runner/config:/config
      - /var/run/docker.sock:/var/run/docker.sock   # optional: container-based jobs
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:exec,size=2g,mode=1777
    stop_grace_period: 30s
    restart: unless-stopped
```

### Ephemeral runners

Set `RUNNER_EPHEMERAL=true` to make the runner accept exactly one job, run it, and exit. The container is then re-created by Docker / your orchestrator and registers as a brand-new runner with a fresh state.

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    container_name: gh-runner-ephemeral
    environment:
      - TZ=Etc/UTC
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx                  # or RUNNER_TOKEN=...
      - RUNNER_EPHEMERAL=true
      - DISABLE_RUNNER_UPDATE=true          # avoid mid-job auto-updates
      - CLEANUP_OFFLINE_RUNNERS=true        # sweep ghost runners on each start
      - LOG_LEVEL=info
      # s6 / Docker stop sequencing — the finish hook needs ~10–20 s to deregister
      - S6_SERVICES_GRACETIME=30000
      - S6_KILL_GRACETIME=30000
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # optional: container-based jobs
    security_opt:
      - no-new-privileges:true
    cap_drop: [ ALL ]
    cap_add: [ CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER ]
    tmpfs:
      - /run:exec,size=64m
      - /tmp:exec,size=2g,mode=1777
      - /var/log:size=32m
    stop_grace_period: 30s
    restart: always
```

> **About `read_only: true`** — the runner writes its registration state into `/opt/runner-bin`, so a blanket `read_only: true` breaks startup. For a hardened posture, rely on `no-new-privileges:true`, `cap_drop: ALL` plus the minimum capability set, and tmpfs for `/run`, `/tmp`, `/var/log`.

### Persistent runner with `/config` volume

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    container_name: gh-runner-org
    environment:
      - TZ=Etc/UTC
      - RUNNER_URL=https://github.com/MY-ORG
      - GITHUB_PAT=ghp_xxx
      - RUNNER_NAME=org-runner-01
      - RUNNER_GROUP=production
      - RUNNER_LABELS=self-hosted,linux,x64,docker
    volumes:
      - /path/to/runner/config:/config
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:exec,size=2g,mode=1777
    stop_grace_period: 30s
    restart: unless-stopped
```

### Recommended: Fixed pool of ephemeral runners

For most users — **including everyone on Balena, Kubernetes, Docker Swarm, or any orchestrator that already restarts crashed containers** — the simplest robust pattern is a **fixed-size pool of ephemeral runners**. No external scheduler, no Docker socket on the scaler, no `docker compose` plumbing inside a container.

How it works:
1. Pick a pool size `N` based on your *peak* concurrent CI demand (start with 2–5; grow as you measure backlog).
2. Run `N` identical replicas, each with `RUNNER_EPHEMERAL=true`. Each replica accepts exactly one job and exits.
3. Your orchestrator (`restart: always` on Docker / `restartPolicy: Always` on K8s / Balena's supervisor) immediately re-creates the exited container, which registers as a brand-new runner ready for the next job.

Pool size stays constant; only the individual container per job rotates. Capacity is always `N`.

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    # No container_name — required for --scale
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - RUNNER_LABELS=self-hosted
      - RUNNER_EPHEMERAL=true
      - CLEANUP_OFFLINE_RUNNERS=true   # sweep ghost runners on each (re)start
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:exec,size=2g,mode=1777
      - /config:size=128m
    restart: always
```

```bash
docker compose up -d --scale gh-runner=3
```

> On Balena, set the pool size with the `replicas` field in your fleet's compose file — no host SSH or `--scale` flag required. On Kubernetes, set `spec.replicas` on the Deployment.

**Outgrow this pattern** only when demand is bursty, idle compute cost is material, *and* you accept the operational cost of a scaler — otherwise the fixed pool is the right answer.

### Advanced: Dynamic scaling

Dynamic scaling here means **varying the count of ephemeral replicas** based on observed busy-ratio. Concurrency comes from the number of replicas, never from anything inside a single container — see [Ephemeral mode and the concurrency model](#ephemeral-mode-and-the-concurrency-model).

The repository ships [`scripts/autoscale.sh`](scripts/autoscale.sh) — a small Bash autoscaler that polls the GitHub API for the busy/online ratio and asks a configurable **backend** to adjust the pool size. The script is baked into the image at `/usr/local/bin/gh-runner-autoscale`, so the sidecar can reuse the same image with no host bind mount of the script.

| `SCALE_BACKEND` | Use it for | What it does |
| --- | --- | --- |
| `compose` *(default)* | Plain Docker / Docker Compose hosts | Calls `docker compose --scale gh-runner=N`. Requires `/var/run/docker.sock` and the rendered compose file mounted into the sidecar. |
| `exec` | Anything you can drive from a shell — Balena, K8s without a controller, Nomad, Swarm, custom orchestrators | Invokes a user-supplied command for `count`, `scale <N>`, and (optionally) `remove <name>...`. Portable to any platform. |
| `emit` | Read-only "decision-as-a-service" | Writes a JSON state file every interval and **never scales locally**. An external system (GitHub Actions cron, balena-cli from a workstation, Argo/Tekton pipeline, …) consumes the file and applies the scaling action however it likes. |

#### Multiple fleets on one org/repo (arm64 + x64, prod + staging, …)

The autoscaler queries the GitHub API for *all* runners registered to `RUNNER_URL` and computes its busy/idle ratio from that set. If you run more than one fleet against the same org or repo — for example an arm64 pool and an x64 pool, or prod and staging — you **must** scope each sidecar to its own fleet, otherwise the metrics are blended and every fleet gets the wrong scaling decision.

Set either or both filters on the **sidecar** (they don't apply to the runner container itself):

| Env var | Effect |
| --- | --- |
| `RUNNER_SCOPE_LABELS` | Comma-separated label set. Only runners whose label set is a **superset** of this list are counted. Case-insensitive. GitHub auto-applies `Linux`/`X64`/`ARM64`/`macOS`, so `ARM64` alone reliably picks the arm64 fleet. |
| `RUNNER_SCOPE_NAME_REGEX` | jq-flavor (PCRE) regex applied to `.name`. Useful when fleets share labels but use distinct name prefixes (e.g. `^arm-runner-`). AND-combined with the label filter. |

Example — two sidecars, one per fleet:

```yaml
  gh-runner-scaler-arm64:
    image: blackoutsecure/github-runner:latest
    entrypoint: ["/usr/local/bin/gh-runner-autoscale"]
    environment:
      - RUNNER_URL=https://github.com/MY-ORG
      - GITHUB_PAT=ghp_xxx
      - SCALE_BACKEND=exec
      - SCALE_EXEC=/usr/local/bin/balena-pool-arm64.sh
      - SCALE_MIN=1
      - SCALE_MAX=10
      - RUNNER_SCOPE_LABELS=self-hosted,arm64
      # OR: RUNNER_SCOPE_NAME_REGEX=^arm-runner-
    restart: always

  gh-runner-scaler-x64:
    image: blackoutsecure/github-runner:latest
    entrypoint: ["/usr/local/bin/gh-runner-autoscale"]
    environment:
      - RUNNER_URL=https://github.com/MY-ORG
      - GITHUB_PAT=ghp_xxx
      - SCALE_BACKEND=exec
      - SCALE_EXEC=/usr/local/bin/balena-pool-x64.sh
      - SCALE_MIN=1
      - SCALE_MAX=10
      - RUNNER_SCOPE_LABELS=self-hosted,x64
    restart: always
```

When no scope filter is set the sidecar logs `Scope filter : <none> -- counting ALL runners in <RUNNER_URL>` at startup so it's obvious when this is unintentional.

The stale-runner cleanup in the runner container has its own scoping knob, [`CLEANUP_OFFLINE_NAME_REGEX`](#stale-offline-runner-cleanup), which serves the same purpose for the DELETE-on-startup sweep.

#### Compose backend (default)

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - RUNNER_LABELS=self-hosted
      - RUNNER_EPHEMERAL=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:exec,size=2g,mode=1777
      - /config:size=128m
    restart: always

  gh-runner-scaler:
    image: blackoutsecure/github-runner:latest
    entrypoint: ["/usr/local/bin/gh-runner-autoscale"]
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - SCALE_BACKEND=compose
      - SCALE_MIN=1
      - SCALE_MAX=5
      - SCALE_MODE=auto           # auto | fixed
      - SCALE_INTERVAL=30         # seconds between checks
      - SCALE_COOLDOWN=60         # seconds between scale events
      - SCALE_UP_THRESHOLD=80     # scale up when ≥N% of runners are busy
      - SCALE_DOWN_THRESHOLD=20   # scale down when ≤N% of runners are busy
      - COMPOSE_SERVICE=gh-runner
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./docker-compose.yml:/workspace/docker-compose.yml:ro
    working_dir: /workspace
    restart: always
    depends_on:
      - gh-runner
```

| `SCALE_MODE` | Behaviour |
| --- | --- |
| `auto` | Scales between `SCALE_MIN` and `SCALE_MAX` based on the busy/online ratio |
| `fixed` | Always maintains exactly `SCALE_MAX` runners (self-heals if one dies) |

For a static replica count without the sidecar, just use `docker compose up -d --scale gh-runner=N`.

**Graceful scale-down (ephemeral mode):** to avoid aborting an in-flight workflow, the autoscaler queries the GitHub API for runners that are `online` AND `busy=false`, picks the idle ones, and asks the backend to stop only those. If no idle runners are available, the autoscaler **defers** scale-in to the next interval rather than killing a busy container. With `SCALE_BACKEND=compose` this is implemented via per-container `docker stop`; with `SCALE_BACKEND=exec` you opt in by setting `SCALE_EXEC_SUPPORTS_REMOVE=true` and implementing the `remove <name>...` verb in your wrapper.

#### Exec backend (orchestrator-agnostic)

Set `SCALE_BACKEND=exec` and point `SCALE_EXEC` at a script. The autoscaler invokes it with one of three verbs:

| Verb | Required | Stdout contract |
| --- | --- | --- |
| `count`                | yes  | Print the current replica count as a non-negative integer, then exit `0`. |
| `scale <N>`            | yes  | Bring the pool to exactly `N` replicas. Exit `0` on success. |
| `remove <name>...`     | optional (gated by `SCALE_EXEC_SUPPORTS_REMOVE=true`) | Retire the specifically-named runners. Exit `0` on success. If you omit this verb, the autoscaler falls back to a naive `scale <new_total>`. |

Minimal Balena wrapper using `balena-cli` (run the sidecar somewhere with a Balena API token in `$BALENA_TOKEN`):

```bash
#!/usr/bin/env bash
set -euo pipefail
FLEET="my-org/runner-fleet"
SERVICE="gh-runner"
case "$1" in
  count)
    balena devices --fleet "$FLEET" --json \
      | jq "[ .[] | select(.is_online and .status == \"Idle\") ] | length"
    ;;
  scale)
    # Update the fleet's compose service replica count via balena-cli
    balena env add --fleet "$FLEET" "${SERVICE^^}_REPLICAS" "$2"
    ;;
  remove)
    # Optional: implement targeted device retirement here, then exit 0
    exit 1
    ;;
esac
```

```yaml
  gh-runner-scaler:
    image: blackoutsecure/github-runner:latest
    entrypoint: ["/usr/local/bin/gh-runner-autoscale"]
    environment:
      - RUNNER_URL=https://github.com/MY-ORG
      - GITHUB_PAT=ghp_xxx
      - BALENA_TOKEN=...
      - SCALE_BACKEND=exec
      - SCALE_EXEC=/usr/local/bin/balena-pool.sh
      - SCALE_MIN=1
      - SCALE_MAX=10
    volumes:
      - ./balena-pool.sh:/usr/local/bin/balena-pool.sh:ro
    restart: always
```

The same shape works for `kubectl scale deployment/gh-runner --replicas=N`, `nomad job scale gh-runner N`, `docker service scale gh-runner=N`, etc.

#### Emit backend (read-only / external scheduler)

When you want the autoscaler to *recommend* a target replica count but not act on it — for example to keep all scaling actions in a GitHub Actions workflow that already has org-admin credentials — use `SCALE_BACKEND=emit`. The script writes one JSON object to `SCALE_EMIT_FILE` each interval:

```json
{
  "ts": "2026-05-17T13:30:33Z",
  "backend": "emit",
  "target": 5,
  "current": 0,
  "online": 4,
  "busy": 3,
  "idle_runner_names": ["runner-aaa", "runner-bbb"]
}
```

```yaml
  gh-runner-scaler:
    image: blackoutsecure/github-runner:latest
    entrypoint: ["/usr/local/bin/gh-runner-autoscale"]
    environment:
      - RUNNER_URL=https://github.com/MY-ORG
      - GITHUB_PAT=ghp_xxx
      - SCALE_BACKEND=emit
      - SCALE_EMIT_FILE=/shared/scale-state.json
      - SCALE_MIN=1
      - SCALE_MAX=10
    volumes:
      - scaler-state:/shared
    restart: always

volumes:
  scaler-state:
```

An external scheduler (cron + `balena-cli`, GitHub Actions, Argo, …) reads `target` from the file and applies it however that environment expects. This is the most portable option — the autoscaler is fully decoupled from your scaling primitive.

#### Kubernetes

For Kubernetes the recommended approach is the **fixed pool** above (Deployment with `replicas: N` and `RUNNER_EPHEMERAL=true`). If you need true demand-driven scaling, prefer GitHub's own [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) which integrates natively with the cluster autoscaler and HPA — the bash autoscaler in this repo is intended for non-K8s environments.

### Balena deployment

This image is published as a Balena block and deploys via `balena push` or the [Deploy button](#docker-github-runner). The repository's `docker-compose.yml` includes the required Balena labels and uses Balena's `balena-socket` feature instead of bind-mounting the host Docker socket.

```bash
balena push <your-app-slug>
```

For deployment via the web interface use the deploy button at the top of this README. See the [Balena documentation](https://docs.balena.io/) for details.

### Docker CLI

```bash
docker run -d \
  --name=gh-runner \
  --restart unless-stopped \
  -e TZ=Etc/UTC \
  -e RUNNER_URL=https://github.com/OWNER/REPO \
  -e GITHUB_PAT=ghp_xxx \
  -e RUNNER_NAME=my-runner \
  -v /path/to/runner/config:/config \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --tmpfs /tmp:exec,size=2g,mode=1777 \
  --stop-timeout 30 \
  blackoutsecure/github-runner:latest
```

## Parameters

### Environment variables

#### Registration

| Variable | Default | Description |
| --- | --- | --- |
| `RUNNER_URL` | _required_ | GitHub repository, organization, or enterprise URL (e.g. `https://github.com/OWNER/REPO`) |
| `RUNNER_TOKEN` | one of three req'd | Runner registration token (expires 1 h after generation) |
| `GITHUB_PAT` | one of three req'd | GitHub Personal Access Token — container auto-mints registration tokens via the API |
| `GITHUB_TOKEN` | one of three req'd | Repo secret or GitHub App token — same auto-mint behaviour as `GITHUB_PAT`, but typically shorter-lived |
| `RUNNER_NAME` | container hostname | Display name; auto-deduplicated (`-1`, `-2`, …) when an online runner with the same name already exists |
| `RUNNER_LABELS` | `self-hosted` | Comma-separated custom labels (e.g. `self-hosted,linux,arm64,gpu`) |
| `RUNNER_GROUP` | `Default` | Runner group (org / enterprise only); created via API if missing |
| `RUNNER_WORKDIR` | `/config/work` | Job working directory |
| `RUNNER_EPHEMERAL` | `false` | When `true`, runner accepts one job, runs it, and exits |
| `RUNNER_REPLACE_EXISTING` | `true` | Replace an existing runner with the same name |
| `DISABLE_RUNNER_UPDATE` | `false` | Disable in-process upstream runner auto-updates |

> One of `RUNNER_TOKEN`, `GITHUB_PAT`, or `GITHUB_TOKEN` is required. Priority: `RUNNER_TOKEN` > `GITHUB_PAT` > `GITHUB_TOKEN`.

#### Docker secrets (file-based credentials)

| Variable | Description |
| --- | --- |
| `RUNNER_URL_FILE` | Path to a file containing `RUNNER_URL` (Docker Compose secrets, Kubernetes projected volumes, etc.) |
| `RUNNER_TOKEN_FILE` | Path to a file containing `RUNNER_TOKEN` |
| `GITHUB_PAT_FILE` | Path to a file containing `GITHUB_PAT` |
| `GITHUB_TOKEN_FILE` | Path to a file containing `GITHUB_TOKEN` |

The `_FILE` variant takes precedence over the plain variant when both are set.

#### Job environment injection

| Variable | Description |
| --- | --- |
| `RUNNER_ENV_FILE` | Path to a `KEY=VALUE` env file injected into the runner's job environment |
| `RUNNER_SECRETS_DIR` | Path to a directory whose files map to env vars (`<filename>=<contents>`) |

#### Docker-in-Docker

| Variable | Default | Description |
| --- | --- | --- |
| `DOCKER_IN_DOCKER` | `false` | Add the runner user to the gid that owns the mounted Docker socket so container-based jobs work |
| `AUTO_DOCKER_LABEL` | follows `DOCKER_IN_DOCKER` | When `true`, auto-appends a `docker` runner label so workflows can target `runs-on: [self-hosted, docker]` |
| `DOCKER_HOST_SOCK` | _auto_ | Override the in-container socket path (default: auto-detect `/var/run/docker.sock` then `/var/run/balena-engine.sock`) |

#### Logging

| Variable | Default | Description |
| --- | --- | --- |
| `LOG_LEVEL` | `info` | Container log verbosity: `debug` < `info` < `warn` < `error` < `fatal` (fatal is always shown) |
| `HEARTBEAT_INTERVAL` | `120` | Seconds between full `HEALTH HEARTBEAT` banners. Minimum 30 |
| `JOB_HEARTBEAT_INTERVAL` | `120` | Seconds between mid-job `JOB HEARTBEAT` banners (only while a job is running). `0` disables; minimum 30 when enabled |

#### Health / liveness

| Variable | Default | Description |
| --- | --- | --- |
| `ONLINE_PROBE_EVERY` | `1` (persistent) / `0` (ephemeral) | Probe the GitHub API for runner status every N heartbeat ticks; `0` disables (requires `GITHUB_PAT` / `GITHUB_TOKEN`) |
| `ONLINE_FAIL_THRESHOLD` | `3` | Consecutive offline detections before triggering `ON_OFFLINE_ACTION` |
| `ON_OFFLINE_ACTION` | `restart` | `none` (log only) \| `restart` (graceful s6 restart) \| `shutdown` (container exits, orchestrator restarts it) |
| `HEALTH_STALE_AFTER` | `300` | Seconds before the Docker `HEALTHCHECK` reports unhealthy if the online sentinel goes stale |

#### Stale offline runner cleanup

See [Stale offline runner cleanup](#stale-offline-runner-cleanup) for the full description.

| Variable | Default | Description |
| --- | --- | --- |
| `CLEANUP_OFFLINE_RUNNERS` | `false` | Master toggle for the startup sweep that DELETEs offline runners from GitHub |
| `CLEANUP_OFFLINE_AFTER` | `86400` | Seconds a runner must be continuously offline before removal (threshold mode); minimum `300` |
| `CLEANUP_OFFLINE_IMMEDIATE` | _auto_ | `true` skips the offline timer. Auto-resolves to `true` when `RUNNER_EPHEMERAL=true`, `false` otherwise |
| `CLEANUP_OFFLINE_NAME_REGEX` | _empty_ | Optional ERE pattern; only matching runner names are eligible |
| `CLEANUP_OFFLINE_DRY_RUN` | `false` | Log what would be removed without calling `DELETE` |
| `CLEANUP_OFFLINE_MAX` | `25` | Safety cap on runners removed per sweep |

#### Custom packages / init script (escape hatch)

| Variable | Description |
| --- | --- |
| `EXTRA_PACKAGES` | Space-separated `apt` packages installed as root before the runner starts. Names validated against `^[a-z0-9][a-z0-9+.\-]+$`. Repeated production use → build a custom image instead |
| `EXTRA_APT_REPOS` | Semicolon-separated `sources.list` lines added before installing `EXTRA_PACKAGES` |
| `EXTRA_INIT_SCRIPT` | Path inside the container to a shell script (typically bind-mounted **read-only**) executed as root before the runner starts. Rejected if world-writable. **Do not** point this at a job-writable path |

#### Process / shutdown

| Variable | Default | Description |
| --- | --- | --- |
| `S6_SERVICES_GRACETIME` | `30000` | s6 service shutdown gracetime (ms) — must be long enough for the runner to deregister |
| `S6_KILL_GRACETIME` | `30000` | s6 hard-kill gracetime (ms) — keep aligned with the Compose / orchestrator `stop_grace_period` |
| `PUID` | `1000` | UID for file ownership (LinuxServer.io baseimage standard) |
| `PGID` | `1000` | GID for file ownership (LinuxServer.io baseimage standard) |
| `FORCE_RUNNER_PERMISSIONS_FIX` | `false` | Force a defensive `chown -R abc:abc /opt/runner-bin` walk at startup (bypasses the build-time ownership marker). Useful after a manual ownership change |

### Autoscaler variables

Used by the `gh-runner-scaler` sidecar service (see [Advanced: Dynamic scaling](#advanced-dynamic-scaling)):

**Common to all backends:**

| Variable | Default | Description |
| --- | --- | --- |
| `SCALE_BACKEND` | `compose` | Scaling backend: `compose` \| `exec` \| `emit` |
| `SCALE_MIN` | `1` | Minimum runners to keep alive |
| `SCALE_MAX` | `1` | Maximum runners allowed |
| `SCALE_MODE` | `auto` | `auto` = scale on demand, `fixed` = always run `SCALE_MAX` |
| `SCALE_INTERVAL` | `30` | Seconds between scaling checks |
| `SCALE_COOLDOWN` | `60` | Seconds between scale events |
| `SCALE_UP_THRESHOLD` | `80` | Scale up when ≥N% of runners are busy |
| `SCALE_DOWN_THRESHOLD` | `20` | Scale down when ≤N% of runners are busy |

**Compose backend (`SCALE_BACKEND=compose`):**

| Variable | Default | Description |
| --- | --- | --- |
| `COMPOSE_SERVICE` | `gh-runner` | Name of the runner compose service to scale |
| `COMPOSE_PROJECT` | _empty_ | Optional compose project name |
| `COMPOSE_FILE` | `docker-compose.yml` | Compose file path (mount it into the scaler) |

**Exec backend (`SCALE_BACKEND=exec`):**

| Variable | Default | Description |
| --- | --- | --- |
| `SCALE_EXEC` | _required_ | Path or shell command invoked with verbs `count`, `scale <N>`, and (optionally) `remove <name>...` |
| `SCALE_EXEC_SUPPORTS_REMOVE` | `false` | Set `true` if your wrapper implements the `remove <name>...` verb for targeted graceful scale-down |

**Emit backend (`SCALE_BACKEND=emit`):**

| Variable | Default | Description |
| --- | --- | --- |
| `SCALE_EMIT_FILE` | _required_ | Path to write the JSON state file each interval |

### Volumes

| Mount | Description | Recommendation |
| --- | --- | --- |
| `-v /config` | Runner configuration, registration state, offline-cleanup ledger, and job workspace | Persistent volume in non-ephemeral mode; tmpfs is fine for ephemeral fleets |
| `-v /var/run/docker.sock:/var/run/docker.sock` | Host Docker socket | Required only for container-based jobs |

## Configuration

### Registration tokens

GitHub registration tokens expire 1 hour after they are minted, so handing one in via `RUNNER_TOKEN` is best suited to one-shot deploys. For long-lived deployments use [GITHUB_PAT](#using-a-github-pat-recommended) or [GITHUB_TOKEN](#using-a-github-app-or-repo-secret-github_token) so the container can auto-mint tokens.

**Generating a registration token manually**

```bash
# Repository
curl -X POST \
  -H "Authorization: token YOUR_GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/OWNER/REPO/actions/runners/registration-token | jq -r '.token'

# Organization
curl -X POST \
  -H "Authorization: token YOUR_GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/orgs/ORG/actions/runners/registration-token | jq -r '.token'
```

### Using a GitHub PAT (recommended)

Provide a PAT via `GITHUB_PAT` and the container will mint a fresh registration token on every start. No manual token rotation, and you can have the container auto-clean up stale offline runners.

Required PAT scopes:

| PAT type | Repo-level | Org-level | Enterprise |
| --- | --- | --- | --- |
| Classic | `repo` | `admin:org` | `manage_runners:enterprise` |
| Fine-grained | `Administration` — read & write | `Self-hosted runners` — read & write | n/a (use classic) |

```bash
docker run -d \
  --name gh-runner \
  -e GITHUB_PAT=ghp_xxx \
  -e RUNNER_URL=https://github.com/OWNER/REPO \
  -v runner-config:/config \
  blackoutsecure/github-runner:latest
```

### Using a GitHub App or repo secret (`GITHUB_TOKEN`)

When deploying from a GitHub Actions workflow you can pass a repo secret PAT or a GitHub App installation token via `GITHUB_TOKEN` — same auto-mint behaviour as `GITHUB_PAT`.

| Source | Example | Notes |
| --- | --- | --- |
| Repo secret | `${{ secrets.RUNNER_PAT }}` | Stored PAT, set per repo |
| GitHub App installation token | `${{ steps.app-token.outputs.token }}` | Generated via [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token); auto-rotates hourly. **Recommended for production fleets** |
| `${{ secrets.GITHUB_TOKEN }}` | Workflow-issued token | Usually **lacks** runner admin permissions; prefer a repo secret PAT or App token |

```yaml
# .github/workflows/deploy-runner.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: |
          docker run -d \
            --name gh-runner \
            -e GITHUB_TOKEN=${{ secrets.RUNNER_PAT }} \
            -e RUNNER_URL=https://github.com/${{ github.repository }} \
            -e RUNNER_NAME=ci-runner-${{ github.run_id }} \
            -e RUNNER_EPHEMERAL=true \
            -v runner-config:/config \
            blackoutsecure/github-runner:latest
```

### Using Docker secrets (`_FILE` variants)

For production, prefer the `_FILE` variants so secrets never appear in `docker inspect` or process env.

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    environment:
      - GITHUB_PAT_FILE=/run/secrets/github_pat
      - RUNNER_URL_FILE=/run/secrets/runner_url
    secrets:
      - github_pat
      - runner_url
    volumes:
      - runner-config:/config
    restart: unless-stopped

secrets:
  github_pat:
    file: ./secrets/github_pat.txt
  runner_url:
    file: ./secrets/runner_url.txt
```

### Injecting custom env into jobs

To expose secrets (NPM tokens, AWS creds, Sonar tokens, …) to every workflow job that runs on this runner, use one of the following — they're loaded once at container start and inherited by `Runner.Worker`.

**1) `RUNNER_ENV_FILE` (env file)**

```bash
# /run/secrets/runner.env
NPM_TOKEN=npm_abc123
AWS_ACCESS_KEY_ID=AKIA...
SONAR_TOKEN=sqp_abc123
```

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    environment:
      - GITHUB_PAT_FILE=/run/secrets/github_pat
      - RUNNER_URL=https://github.com/OWNER/REPO
      - RUNNER_ENV_FILE=/run/secrets/runner.env
    volumes:
      - ./secrets/runner.env:/run/secrets/runner.env:ro
      - runner-config:/config
    secrets: [ github_pat ]
```

**2) `RUNNER_SECRETS_DIR` (one file per secret — works with Docker / Kubernetes native secrets)**

```text
secrets/custom/
├── NPM_TOKEN          # contents: npm_abc123
├── AWS_ACCESS_KEY_ID  # contents: AKIA...
└── SONAR_TOKEN        # contents: sqp_abc123
```

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    environment:
      - RUNNER_SECRETS_DIR=/run/secrets/custom
    volumes:
      - ./secrets/custom:/run/secrets/custom:ro
      - runner-config:/config
```

**3) Direct `-e` flags** — simplest for one-off setups.

Precedence: direct `-e` env → `RUNNER_ENV_FILE` → `RUNNER_SECRETS_DIR` (later values override earlier ones).

## Privileges required by feature

The image is designed to run with the **minimum** privileges that still let s6-overlay supervise the runner and drop it to the unprivileged `abc` user (uid 911). Everything else is additive.

### Minimum baseline

| Requirement | Value | Why |
| --- | --- | --- |
| Container user (PID 1) | `root` | s6-overlay init scripts need root to chown `/run` and drop to `abc` |
| Linux capabilities | `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, `FOWNER` | s6-overlay ownership / privilege drop |
| `security_opt` | `no-new-privileges=true` | Block setuid escalation inside the container |
| `cap_drop` | `ALL` (then re-add the five above) | Drops every other capability |
| Tmpfs | `/run`, `/tmp`, `/var/log` (sized per workload) | s6 service state, job scratch, supervisor logs |
| Egress | `https://api.github.com`, `https://github.com`, `https://*.actions.githubusercontent.com` | Registration, listener long-poll, artifact / log upload |
| Required env | `RUNNER_URL` + one of `RUNNER_TOKEN` / `GITHUB_PAT` / `GITHUB_TOKEN` | Authenticates registration |

Notably **`NET_ADMIN`, `SYS_ADMIN`, and `SYS_PTRACE` are never required**.

### Per-feature additions

| Feature / variable | Extra container privilege | Host requirement | GitHub token scope |
| --- | --- | --- | --- |
| `RUNNER_TOKEN` only | none | none | none (token already minted) |
| `GITHUB_PAT` / `GITHUB_TOKEN` (auto-mint) | none | none | classic: `repo` (repo) / `admin:org` (org); fine-grained: `Administration: write` (repo) or `Self-hosted runners: write` (org) |
| `RUNNER_EPHEMERAL=true` | none | container restart policy that recreates after exit | same as registration |
| `RUNNER_ENV_FILE` / `RUNNER_SECRETS_DIR` | none | mounted file/dir readable by uid 911 | none |
| `EXTRA_PACKAGES` / `EXTRA_APT_REPOS` | PID 1 = root | egress to apt mirrors; rootfs writable | none |
| `EXTRA_INIT_SCRIPT` | PID 1 = root; rejected if world-writable | script bind-mounted **read-only** outside any job-writable path | none |
| `DOCKER_IN_DOCKER=true` | PID 1 = root (for `usermod` group fixup) | engine socket bind-mount (or Balena `balena-socket` feature) | none |
| `DOCKER_IN_DOCKER=true` + non-root | none in-container | chosen uid must be a member of host docker gid (`group_add` or `user: "911:<docker-gid>"`) | none |
| `ONLINE_PROBE_EVERY` (with API check) | none | none | read-only flavour of registration scope (classic `repo` / `admin:org`; fine-grained read) |
| `ON_OFFLINE_ACTION=restart` (default) | none | none | none |
| `ON_OFFLINE_ACTION=shutdown` | none | orchestrator restart policy that recreates the container | none |
| `HEALTH_STALE_AFTER` | none | Docker engine ≥ 1.12 honouring `HEALTHCHECK` | none |
| `CLEANUP_OFFLINE_RUNNERS=true` | none | persistent `/config` (offline ledger lives in `/config/.gh-runner-offline-state.json`) | same as registration |
| `RUNNER_GROUP` create-if-missing (org / enterprise) | none | none | same as registration |
| `PUID` / `PGID` | PID 1 = root (for LSIO `usermod`) | none | none |
| `S6_SERVICES_GRACETIME` / `S6_KILL_GRACETIME` / `stop_grace_period` | none | orchestrator must respect the configured grace | none |

### GitHub API endpoints by variable

| Variable / feature | API call(s) | Min classic scope | Min fine-grained permission |
| --- | --- | --- | --- |
| Registration token mint | `POST /{scope}/actions/runners/registration-token` | repo: `repo` · org: `admin:org` · ent: `manage_runners:enterprise` | repo: `Administration: write` · org: `Self-hosted runners: write` |
| Pre-flight token introspection | `GET /user` (for `X-OAuth-Scopes`) | any | any |
| Online probe (`ONLINE_PROBE_EVERY > 0`) | `GET /{scope}/actions/runners` (paginated) | read flavour of above (repo `repo`, org `admin:org` or `read:org`, ent `manage_runners:enterprise`) | read flavour of above |
| `RUNNER_GROUP` create-if-missing | `GET`/`POST /{scope}/actions/runner-groups` | org: `admin:org` · ent: `manage_runners:enterprise` | org: `Self-hosted runners: read & write` |
| `CLEANUP_OFFLINE_RUNNERS` list | `GET /{scope}/actions/runners` | same as online probe | same as online probe |
| `CLEANUP_OFFLINE_RUNNERS` delete | `DELETE /{scope}/actions/runners/{id}` | same as registration | same as registration |
| Removal-token mint (graceful shutdown) | `POST /{scope}/actions/runners/remove-token` | same as registration | same as registration |
| `RUNNER_TOKEN`-only setup, no probe, no cleanup | none from this container | n/a | n/a |
| All other variables | none | n/a | n/a |

### Minimum-token cookbook

| Setup | Minimum classic PAT | Minimum fine-grained PAT |
| --- | --- | --- |
| Repo, `RUNNER_TOKEN` only | none (registration token is self-contained) | n/a |
| Repo, auto-mint only | `repo` | `Administration: read & write` (repo) |
| Repo, auto-mint + online probe + cleanup | `repo` | `Administration: read & write` (repo) |
| Org, auto-mint only | `admin:org` | `Self-hosted runners: read & write` (org) |
| Org, auto-mint + group + probe + cleanup | `admin:org` | `Self-hosted runners: read & write` (org) |
| Enterprise, full feature set | `manage_runners:enterprise` | not generally available — use classic PAT or a GitHub App |

## User / Group Identifiers

The container follows the LinuxServer.io conventions. By default PID 1 starts as root, the s6 init layer chowns runtime directories to UID/GID 911 (the `abc` user), then the runner service is dropped via `s6-setuidgid abc`. `PUID` and `PGID` can be set to align with file ownership on bind-mounted volumes.

LSIO non-root mode (`user: "911:911"`) is supported on a best-effort basis — see [Non-root mode](#non-root-mode-lsio---user) for the caveats.

## Application setup notes

### Ephemeral mode and the concurrency model

`RUNNER_EPHEMERAL=true` makes the upstream `Runner.Listener` single-shot: each container picks up exactly **one job**, runs it, and exits. With `restart: always` the container is re-created and registers as a brand-new runner. There is no upstream knob for "N jobs per listener" in ephemeral mode — this is how `--ephemeral` is defined by GitHub.

> **One ephemeral container = capacity for one concurrent job.** Concurrency on a host comes from running **multiple replicas**; only the exited container is recreated, not the host or other services.

If you need *N* jobs to run at the same time:

- Use `docker compose up -d --scale gh-runner=N`, or
- Run the `gh-runner-scaler` sidecar with `SCALE_MAX=N` (see [Advanced: Dynamic scaling](#advanced-dynamic-scaling)).

If you need persistent multi-job capacity from a single container, drop `RUNNER_EPHEMERAL=true` — the listener will then accept back-to-back jobs serially (still only one at a time, by upstream design).

### Docker-in-Docker (container-based jobs)

Set `DOCKER_IN_DOCKER=true` and bind-mount the host Docker socket to enable container-based GitHub Actions (`jobs.<id>.container:`, service containers, `uses: docker://image`):

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - DOCKER_IN_DOCKER=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
```

What happens when `DOCKER_IN_DOCKER=true`:

1. The init step inspects the gid of `/var/run/docker.sock`, creates a matching group inside the container if missing, and adds `abc` to it so the runner can talk to the host Docker daemon.
2. A `docker` label is auto-appended to `RUNNER_LABELS` (unless `AUTO_DOCKER_LABEL=false`) so workflows can target `runs-on: [self-hosted, docker]`.
3. A preflight check (`docker-in-docker`) verifies the socket is reachable and **fails startup** with a clear message if it isn't.

> **Security**: Granting access to `/var/run/docker.sock` is equivalent to giving the container root on the host. Only enable `DOCKER_IN_DOCKER=true` on trusted infrastructure, and prefer a [socket proxy](https://github.com/Tecnativa/docker-socket-proxy) when running untrusted workflows.

For Balena devices, set the `io.balena.features.balena-socket: '1'` service label instead — the image auto-detects `/var/run/balena-engine.sock`.

#### `DOCKER_IN_DOCKER` + LSIO non-root (`--user`)

The in-container group fixup needs root to `usermod`. In non-root mode it is skipped, so the chosen uid must already belong to the host docker gid:

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    user: "911:999"            # 999 = host docker gid (getent group docker | cut -d: -f3)
    group_add: [ "999" ]
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - DOCKER_IN_DOCKER=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    tmpfs:
      - /run:uid=911,gid=999,exec,size=64m
      - /tmp:exec,size=2g,mode=1777
    security_opt:
      - no-new-privileges:true
    restart: always
```

The preflight check will fail with an actionable message if the chosen uid still can't reach the socket.

### Custom packages / init scripts

The image runs an optional init oneshot **as root before** the runner service drops to `abc`, giving you a controlled hook to install extra tooling or run setup logic without rebuilding the image.

> **⚠ Security: production warning**
> `EXTRA_PACKAGES`, `EXTRA_APT_REPOS`, and `EXTRA_INIT_SCRIPT` run as **root inside the container on every start**. Treat them as you would root credentials.
>
> - Do **not** populate them from untrusted sources (workflow inputs, secrets owned by external contributors, dynamic env files written by jobs, etc.).
> - Do **not** point `EXTRA_INIT_SCRIPT` at a path inside `/config`, `/tmp`, or anywhere a job can write.
> - Pin `EXTRA_APT_REPOS` to repositories you trust.
> - For repeated production use, **build a custom image** — it's reproducible, auditable in source control, and works alongside hardened filesystem modes.

Built-in safeguards (do not rely on these alone):

- `EXTRA_PACKAGES` names are validated against `^[a-z0-9][a-z0-9+.\-]+$`.
- `EXTRA_INIT_SCRIPT` is rejected if it is world-writable.
- Read-only rootfs is detected early and aborts cleanly with an actionable message.
- Non-root mode silently skips the apt steps rather than running them unprivileged.

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - EXTRA_PACKAGES=ffmpeg rsync
      - EXTRA_INIT_SCRIPT=/setup/install-tools.sh
    volumes:
      - ./setup:/setup:ro
      - /var/run/docker.sock:/var/run/docker.sock
    restart: always
```

**Recommended alternative — a thin custom image**:

```dockerfile
FROM blackoutsecure/github-runner:latest
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg rsync \
 && rm -rf /var/lib/apt/lists/*
USER abc
```

Zero startup cost, reproducible, and survives any future hardening of the runtime image.

### Non-root mode (LSIO `--user`)

If your security policy requires that the container's PID 1 itself runs unprivileged, you can opt in to LSIO's [non-root mode](https://docs.linuxserver.io/misc/non-root/):

```yaml
services:
  gh-runner:
    image: blackoutsecure/github-runner:latest
    user: "911:911"
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - RUNNER_EPHEMERAL=true
    tmpfs:
      - /run:uid=911,gid=911,exec,size=64m   # required when combined with no-new-privileges
      - /tmp:exec,size=2g,mode=1777
      - /config:uid=911,gid=911,size=128m
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    cap_drop: [ ALL ]
    restart: always
```

| Caveat | Detail |
| --- | --- |
| `PUID`/`PGID` ignored | The uid/gid is fixed by `--user`. Pick a uid your mounted volumes already accept |
| `EXTRA_PACKAGES` ignored | apt requires root; the init step warns and skips |
| `EXTRA_INIT_SCRIPT` runs unprivileged | Any root-only operation inside will fail |
| `DOCKER_IN_DOCKER` requires host-side setup | See [DOCKER_IN_DOCKER + non-root](#docker_in_docker--lsio-non-root---user) |
| `no-new-privileges=true` | Requires `/run` tmpfs owned by the container's uid |

## Stale offline runner cleanup

Crashed or force-killed containers (SIGKILL, host reboot, power loss) skip the `finish` deregistration hook and leave a runner registered as `offline` in GitHub. Ephemeral fleets are particularly prone to accumulating these ghosts because every container registers under a fresh hostname.

Enable the startup sweep with `CLEANUP_OFFLINE_RUNNERS=true` and a `GITHUB_PAT`/`GITHUB_TOKEN` that carries the same scope used for registration.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLEANUP_OFFLINE_RUNNERS` | `false` | Master toggle. The sweep is a no-op unless this is `true` and a token is available |
| `CLEANUP_OFFLINE_IMMEDIATE` | _auto_ | When `true`, bypass the offline-since timer. Auto-resolves to `true` when `RUNNER_EPHEMERAL=true` (offline ephemeral runners never reconnect), `false` otherwise |
| `CLEANUP_OFFLINE_AFTER` | `86400` | Seconds a runner must be continuously offline before removal in threshold mode (minimum `300`). Persisted via `/config/.gh-runner-offline-state.json` so brief reboots don't reset the timer |
| `CLEANUP_OFFLINE_NAME_REGEX` | _empty_ | Optional ERE pattern to scope the sweep (e.g. `^aada` to limit cleanup to ephemeral hash-named runners) |
| `CLEANUP_OFFLINE_DRY_RUN` | `false` | When `true`, log what would be removed without calling `DELETE`. **Recommended for the first deploy** |
| `CLEANUP_OFFLINE_MAX` | `25` | Safety cap on removals per startup sweep |

**Built-in safety**

- The runner this container is about to register is always excluded from the victim set.
- All deletions are logged with name, id, and offline duration so the action is auditable in `docker logs`.
- Preflight validates the regex (jq compile check), the threshold value, and `/config` writability before any DELETE.

**Recommended config — ephemeral fleet**

```yaml
environment:
  - RUNNER_EPHEMERAL=true
  - GITHUB_PAT=ghp_xxx
  - CLEANUP_OFFLINE_RUNNERS=true
  # CLEANUP_OFFLINE_IMMEDIATE=true   # implicit when ephemeral
  # CLEANUP_OFFLINE_DRY_RUN=true     # try this first
  - CLEANUP_OFFLINE_MAX=25
```

**Recommended config — persistent fleet (24 h grace)**

```yaml
environment:
  - GITHUB_PAT=ghp_xxx
  - CLEANUP_OFFLINE_RUNNERS=true
  - CLEANUP_OFFLINE_AFTER=86400
```

## Health monitoring

### Docker `HEALTHCHECK`

The image ships `/usr/local/bin/gh-runner-healthcheck`, invoked by the Dockerfile's `HEALTHCHECK`. It passes when:

1. The `Runner.Listener` process is alive, AND
2. The `/run/gh-runner/online` sentinel was refreshed in the last `HEALTH_STALE_AFTER` seconds (default 300).

The sentinel is refreshed by the heartbeat loop in `svc-gh-runner-logs`. When a `GITHUB_PAT` / `GITHUB_TOKEN` is available, the heartbeat first verifies via the GitHub API that the runner shows as `online` — so a runner that is process-alive but disconnected from GitHub will go unhealthy.

| Setting | Value |
| --- | --- |
| Interval | `30s` |
| Timeout | `10s` |
| Start period | `300s` (covers slow first-time runner extraction / register) |
| Retries | `5` |

```bash
docker inspect --format='{{.State.Health.Status}}' gh-runner
```

### Auto-recovery on disconnection

If the runner is reported `offline` by GitHub for `ONLINE_FAIL_THRESHOLD` consecutive heartbeats (~6 min with defaults), the heartbeat loop takes `ON_OFFLINE_ACTION`:

| Action | Behaviour |
| --- | --- |
| `none` | Log only — let the Docker `HEALTHCHECK` and your orchestrator decide |
| `restart` *(default)* | Graceful restart of `svc-gh-runner` via `s6-svc -r` (keeps the container, re-registers the listener) |
| `shutdown` | Tear the container down so `restart: always` brings it back fresh |

### s6 service supervision

```bash
docker exec gh-runner s6-svstat /run/service/svc-gh-runner
```

## Logging

The image emits structured single-line logs in the format:

```
<RFC3339 UTC timestamp> <component>[<level>]: <message>
```

…and longer multi-line banner blocks for major events (container start, job start / finish, periodic health heartbeat). All output goes to `docker logs` / `balena logs`. Highlights:

- **Severity threshold** — `LOG_LEVEL` filters everything below the chosen level. `fatal` is always emitted.
- **Two heartbeats** — `HEARTBEAT_INTERVAL` (default 120 s) drives the heavyweight `HEALTH HEARTBEAT` banner with process state, online probe, uptime, load, disk, and per-worker breakdown. `JOB_HEARTBEAT_INTERVAL` (default 120 s, `0` to disable) emits a lighter mid-job heartbeat only while a `Runner.Worker` is active.
- **Job start / finish banners** — fire the moment a `Runner.Worker` process appears / disappears, even when the heartbeat cadence is slow.
- **Diag tail with noise filter** — `svc-gh-runner-logs` tails `_diag/Runner_*.log` and `_diag/Worker_*.log`, suppressing chatty boilerplate classes (e.g. `ActionManifestManager` JSON value-tree dumps) that would otherwise overwhelm log shippers. Full payloads are still preserved on disk in `_diag/`.
- **Shutdown durability** — the `finish` hook pins its output to `/proc/1/fd/1` and `/proc/1/fd/2` so the deregister log lines survive the s6 teardown race and are still visible in `docker logs --tail` after the container exits.
- **No secrets in logs** — `GITHUB_PAT` / `GITHUB_TOKEN` / `RUNNER_TOKEN` are never logged in plaintext; the startup banner shows only a masked digest fingerprint for verification.

For log shippers that consume JSON, parse the timestamp prefix or place the runner behind a log driver that adds JSON envelopes (e.g. `journald` + `fluentd`).

## Security considerations

This image is published publicly. The runner has broad access to whatever workflows you allow on it, so the security posture matters a great deal.

**Defaults that are already on**

- `no-new-privileges:true` recommended in every compose example.
- `cap_drop: ALL` + only the 5 capabilities s6-overlay actually needs.
- Runner process dropped from root → `abc` (uid 911) via `s6-setuidgid` after init.
- Secrets accepted via `_FILE` variants and never logged in plaintext.
- Build-time `chown` marker on `/opt/runner-bin` to avoid a multi-second recursive `chown` at every cold start.
- Health probe doubles as a connectivity check — a runner that is process-alive but cannot talk to GitHub is reported unhealthy.
- Stale offline runner sweep is gated by an explicit toggle, a name-regex scope, a `MAX` cap, and a `DRY_RUN` mode.

**Operator responsibilities**

- **Never run untrusted workflows on a runner with `/var/run/docker.sock` mounted unproxied.** Socket access is host-root equivalent. Use a [socket proxy](https://github.com/Tecnativa/docker-socket-proxy) for shared / public CI.
- **Pin the image tag in production** (`blackoutsecure/github-runner:2.333.1` or `:sha-<commit>`), not `:latest`.
- **Use ephemeral runners (`RUNNER_EPHEMERAL=true`) for public / pull-request workflows.** A persistent runner that has handled a previous job is one filesystem write away from leaking secrets into the next job.
- **Restrict PAT scope** to the [minimum-token cookbook](#minimum-token-cookbook) row that matches your enabled features.
- **Prefer GitHub App installation tokens** over long-lived classic PATs for production fleets — they rotate hourly.
- **Treat `EXTRA_PACKAGES` / `EXTRA_INIT_SCRIPT` as root credentials.** Build a custom image for production use.
- **Set `stop_grace_period: 30s` (or more) explicitly.** Docker's default of 10 s will SIGKILL the container mid-deregister and leave a stale runner registered in GitHub.

**Reporting vulnerabilities**

Please follow the responsible disclosure process in the [Blackout Secure security policy](https://github.com/blackoutsecure/docker-github-runner/security/policy). Do **not** open public issues for security reports.

## Troubleshooting

### Container won't start

```bash
docker logs gh-runner --tail 100
```

Common causes:

- **Missing `RUNNER_URL`** — set it to a repo/org/enterprise URL.
- **Expired `RUNNER_TOKEN`** — tokens expire after 1 h. Switch to `GITHUB_PAT` / `GITHUB_TOKEN` for auto-mint.
- **Runner name collision** — set a unique `RUNNER_NAME` or rely on the built-in `-1`, `-2` dedup.
- **Insufficient PAT scope** — the preflight will print the missing scope and the exact endpoint that returned 401/403.

### Runner appears offline in GitHub

```bash
docker ps --filter name=gh-runner
docker inspect --format='{{.State.Health.Status}}' gh-runner
docker logs gh-runner 2>&1 | tail -50
```

If the heartbeat shows `OFFLINE per GitHub API` and the listener is alive, the runner is process-alive but disconnected. The default `ON_OFFLINE_ACTION=restart` recovers after `ONLINE_FAIL_THRESHOLD` (default 3) consecutive failures.

### Runner won't pick up jobs

- Confirm the runner is **Idle** in `Settings → Actions → Runners`.
- The workflow's `runs-on` must match every label the runner advertises (or use `[self-hosted]` for the broadest match).
- For org runners, verify it's assigned to the correct **runner group**.

### Container shuts down before deregistering

If you see a stale `offline` runner in GitHub after every `docker stop`, the `finish` hook didn't have time to run.

```yaml
stop_grace_period: 30s            # MUST be >= S6_KILL_GRACETIME (default 30000ms)
environment:
  - S6_KILL_GRACETIME=30000
  - S6_SERVICES_GRACETIME=30000
```

Docker's default `stop_grace_period` is only 10 s — too short for the API DELETE + fallback path to complete on a slow link.

### Slow first-job latency (`Starting process...` takes a while)

The first job after registration extracts the .NET runner into `_work/` and warms up the `Runner.Worker` process. Subsequent jobs on the same container reuse that state.

For ephemeral fleets, expect ~3–10 s of one-time setup per container before the first action step runs. If the latency budget matters, consider:

- A larger `SCALE_MIN` so the autoscaler keeps warm replicas ready.
- Persistent (non-ephemeral) runners for low-volume / latency-sensitive repos.

## Release & versioning

- **Versioning** — tags follow the upstream [`actions/runner`](https://github.com/actions/runner) release version (e.g. `2.333.1`).
- **Build pipeline** — [`.github/workflows/bos-launchpad.yml`](.github/workflows/bos-launchpad.yml) is the sole workflow in this repo. It thin-wraps the [`bos-launchpad.yml`](https://github.com/blackoutsecure/bos-automation-hub/blob/main/.github/workflows/bos-launchpad.yml) reusable meta-workflow in [`blackoutsecure/bos-automation-hub`](https://github.com/blackoutsecure/bos-automation-hub), which runs monitor → docker → balena → github-release end-to-end. Triggers: 6-hourly cron (upstream-gated), push to `main` on `Dockerfile` / `root/**` / `build/**` / `docker-compose.yml` / `README.md` / `.github/upstream/**` / the workflow itself, and manual `workflow_dispatch` (with a `force_release` flag).
- **Multi-arch builds** — `linux/amd64` + `linux/arm64` via `docker buildx`; the registry tag is a multi-arch manifest list.
- **Image tags** — `:latest`, `:<runner-version>`, `:<runner-version>-<short-vcs-ref>`, `:sha-<short-git-sha>`.
- **Balena block** — `balena.yml` is **not** checked in; the hub renders it on each run from the inputs in [`bos-launchpad.yml`](.github/workflows/bos-launchpad.yml). A local `balena push <fleet-slug>` deploys the published image (via [`docker-compose.yml`](docker-compose.yml)) and does not need `balena.yml`.

```bash
docker pull blackoutsecure/github-runner:latest   # rolling
docker pull blackoutsecure/github-runner:2.333.1  # pinned
docker compose up -d                              # apply
```

## Support

- **Questions / feature requests** — [GitHub Discussions](https://github.com/blackoutsecure/docker-github-runner/discussions) (preferred) or [Issues](https://github.com/blackoutsecure/docker-github-runner/issues)
- **Bug reports** — include image tag (`docker inspect gh-runner --format '{{ index .Config.Labels "org.opencontainers.image.version" }}'`), `docker logs --tail 200`, and the minimum compose / CLI invocation that reproduces it
- **Security reports** — see the [Blackout Secure security policy](https://github.com/blackoutsecure/docker-github-runner/security/policy)

## References

| Resource | Link |
| --- | --- |
| Docker Hub image | [`blackoutsecure/github-runner`](https://hub.docker.com/r/blackoutsecure/github-runner) |
| GitHub repository | [`blackoutsecure/docker-github-runner`](https://github.com/blackoutsecure/docker-github-runner) |
| Issues | [Report bugs / feature requests](https://github.com/blackoutsecure/docker-github-runner/issues) |
| Releases | [Download release notes](https://github.com/blackoutsecure/docker-github-runner/releases) |
| Upstream runner | [`actions/runner`](https://github.com/actions/runner) |
| Self-hosted runner docs | [GitHub Docs](https://docs.github.com/en/actions/hosting-your-own-runners) |
| LinuxServer.io baseimage | [`linuxserver/baseimage-ubuntu`](https://hub.docker.com/r/linuxserver/baseimage-ubuntu) |
| s6-overlay | [`just-containers/s6-overlay`](https://github.com/just-containers/s6-overlay) |
| Balena | [docs.balena.io](https://docs.balena.io/) |

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE). The upstream GitHub Actions Runner is also MIT-licensed; see [actions/runner](https://github.com/actions/runner).

---

Made with care by [Blackout Secure](https://blackoutsecure.app/).
