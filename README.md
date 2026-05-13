# blackoutsecure/docker-github-runner

[![GitHub Stars](https://img.shields.io/github/stars/blackoutsecure/docker-github-runner.svg?style=flat-square)](https://github.com/blackoutsecure/docker-github-runner/stargazers)
[![Docker Pulls](https://img.shields.io/docker/pulls/blackoutsecure/docker-github-runner.svg?style=flat-square)](https://hub.docker.com/r/blackoutsecure/docker-github-runner)
[![GitHub Release](https://img.shields.io/github/release/blackoutsecure/docker-github-runner.svg?style=flat-square)](https://github.com/blackoutsecure/docker-github-runner/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)

Unofficial community image for [GitHub Actions Runner](https://github.com/actions/runner), built with s6 process supervision, hardened defaults, and non-root operation for self-hosted CI/CD workloads.

Sponsored and maintained by [Blackout Secure](https://blackoutsecure.app/).

> **Important**
> This repository is not an official LinuxServer.io image release.

## Overview

This project packages upstream [actions/runner](https://github.com/actions/runner) into an easy-to-run container image with practical defaults for GitHub Actions self-hosted runners.

Quick links:

- Docker Hub listing: [blackoutsecure/docker-github-runner](https://hub.docker.com/r/blackoutsecure/docker-github-runner)
- Balena block listing: [gh-runner block on Balena Hub](https://hub.balena.io/blocks/gh-runner)
- GitHub repository: [blackoutsecure/docker-github-runner](https://github.com/blackoutsecure/docker-github-runner)
- Upstream application: [actions/runner](https://github.com/actions/runner)

[![balena deploy button](https://www.balena.io/deploy.svg)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/blackoutsecure/docker-github-runner&configUrl=https://raw.githubusercontent.com/blackoutsecure/docker-github-runner/main/balena.yml)

## Table of Contents

- [Quick Start](#quick-start)
- [Image Availability](#image-availability)
- [About The Application](#about-the-application)
- [Supported Architectures](#supported-architectures)
- [Usage](#usage)
  - [Docker Compose](#docker-compose-recommended-click-here-for-more-info)
  - [Docker CLI](#docker-cli-click-here-for-more-info)
  - [Balena Deployment](#balena-deployment)
  - [Multiple Runners](#multiple-runners)
  - [Autoscaling](#autoscaling)
- [Parameters](#parameters)
- [Configuration](#configuration)
- [Privileges Required by Feature](#privileges-required-by-feature)
- [User / Group Identifiers](#user--group-identifiers)
- [Application Setup](#application-setup)
- [Stale Offline Runner Cleanup](#stale-offline-runner-cleanup)
- [Troubleshooting](#troubleshooting)
- [Cold-start performance](#cold-start-performance)
- [Health Monitoring](#health-monitoring)
- [Release & Versioning](#release--versioning)
- [Support & Getting Help](#support--getting-help)
- [References](#references)

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
  blackoutsecure/docker-github-runner:latest
```

Check runner status: `docker logs gh-runner`

For compose files, ephemeral mode, and more examples, see [Usage](#usage) below.

## Image Availability

Docker Hub (Recommended):

- All images published to [Docker Hub](https://hub.docker.com/r/blackoutsecure/docker-github-runner)
- Simple pull command: `docker pull blackoutsecure/docker-github-runner:latest`
- Multi-arch support: amd64 (x86-64), arm64

```bash
# Pull latest
docker pull blackoutsecure/docker-github-runner:latest

# Pull specific version
docker pull blackoutsecure/docker-github-runner:2.333.1
```

### Available Tags

| Tag | Description |
| --- | --- |
| `latest` | Latest release (Ubuntu 24.04 Noble, multi-arch amd64 + arm64) |
| `2.333.1` | Pinned version |
| `sha-<commit>` | Git commit SHA |

All tags are multi-arch manifests — Docker automatically pulls the correct image for your host architecture (amd64 or arm64).

## About The Application

[GitHub Actions Runner](https://github.com/actions/runner) is the official self-hosted runner application for GitHub Actions. It allows you to run GitHub Actions workflows on your own infrastructure, providing control over hardware, operating system, and software configurations.

- **Upstream repository:** [actions/runner](https://github.com/actions/runner)
- **Maintained by:** GitHub / Microsoft

## Supported Architectures

All images are published as multi-arch manifests. Pulling any tag retrieves the correct image for your host architecture.

| Architecture | Platform | Tag |
| --- | --- | --- |
| x86-64 | linux/amd64 | amd64-latest |
| ARM 64-bit | linux/arm64 | arm64v8-latest |

## Usage

### docker-compose (recommended, [click here for more info](https://docs.linuxserver.io/general/docker-compose))

```yaml
---
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    container_name: gh-runner
    environment:
      - TZ=Etc/UTC
      - RUNNER_URL=https://github.com/OWNER/REPO
      - RUNNER_TOKEN=YOUR_REGISTRATION_TOKEN
      - RUNNER_NAME=my-runner
      # - RUNNER_LABELS=self-hosted,linux,x64
      # - RUNNER_EPHEMERAL=false
      # - DISABLE_RUNNER_UPDATE=false
    volumes:
      - /path/to/runner/config:/config
      - /var/run/docker.sock:/var/run/docker.sock  # optional: container actions
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:mode=1777
    restart: unless-stopped
```

### Balena Deployment

This image can be deployed to Balena-powered IoT devices using the included `docker-compose.yml` file (which contains the required Balena labels):

- Balena block listing: [gh-runner block on Balena Hub](https://hub.balena.io/blocks/gh-runner)

```bash
balena push <your-app-slug>
```

For deployment via the web interface, use the deploy button in this repository.
See [Balena documentation](https://docs.balena.io/) for details.

### docker-compose (ephemeral mode — autoscaling, read-only hardened)

The image is structured to support `read_only: true` in ephemeral mode.
The runner install lives at the immutable `/opt/runner-bin`; an init step
populates the writable `/opt/actions-runner` runtime tree from it at boot.
No persistent volume is needed because every job runs in a fresh container.

> **Cold-start tip:** do **NOT** mount a `tmpfs` at `/opt/actions-runner`.
> A tmpfs is a separate kernel mount (own `st_dev`), so the boot-time
> hard-link bootstrap fails with `EXDEV` and falls back to a full
> recursive **copy of ~200 MB of .NET runner binaries** on every container
> start. Leaving `/opt/actions-runner` on the container's writable layer
> lets the bootstrap hard-link from `/opt/runner-bin` instead (typically
> ~150 ms vs several seconds). With `read_only: true` you must still
> provide `/opt/actions-runner` as a tmpfs (the rootfs is immutable) — in
> that case the copy is unavoidable; size the tmpfs to fit the full
> extracted runner (~300 MB).

```yaml
---
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    container_name: gh-runner-ephemeral
    environment:
      - TZ=Etc/UTC
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx                 # or RUNNER_TOKEN=...
      - RUNNER_EPHEMERAL=true
      - DISABLE_RUNNER_UPDATE=true         # recommended with read_only
      - LOG_LEVEL=info
      - ON_OFFLINE_ACTION=restart
      # s6 / Docker stop sequencing — finish-script needs time to deregister
      - S6_SERVICES_GRACETIME=30000
      - S6_KILL_GRACETIME=30000
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # optional: container actions
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - FOWNER
    tmpfs:
      - /run:exec,size=64m                  # required by s6-overlay
      - /tmp:exec,size=64m,mode=1777        # mode=1777 lets the abc runner user (and tools like docker/setup-buildx) write here
      - /var/log:size=32m
      - /opt/actions-runner:exec,size=512m  # required only because read_only:true; forces a full copy at boot
      - /config:exec,size=128m              # ephemeral state + work dir
    stop_grace_period: 30s
    restart: always
```

**Required tmpfs mounts (read-only mode):**

| Mount | Why it's needed |
| --- | --- |
| `/run:exec,size=64m` | LSIO baseimage requirement — s6-overlay writes service files here; `exec` is mandatory |
| `/tmp:exec,size=64m` | `Runner.Worker` extracts and executes job scripts here |
| `/var/log:size=32m` | s6 service supervisor logs |
| `/opt/actions-runner:exec,size=512m` | Runtime copy of the runner binaries from immutable `/opt/runner-bin` plus runner state (`.runner`, `.credentials`, `_diag/`, `_work/`); `exec` is required to launch `Runner.Listener`. Sized to fit a full extracted runner (~300 MB) since tmpfs is on a different filesystem than `/opt/runner-bin` and falls back to copy mode. **Only mount this when `read_only: true`** — without it the bootstrap can hard-link and avoid the copy |
| `/config:exec,size=128m` | Ephemeral state and `RUNNER_WORKDIR` (replaces the previous named volume) |

> The healthcheck sentinel directory `/run/gh-runner` is auto-created by the runner service inside the `/run` tmpfs — no separate mount required.

**Required Linux capabilities (with `cap_drop: ALL`):**

| Capability | Purpose |
| --- | --- |
| `CHOWN` | s6-overlay chowns `/run` and runtime dirs to abc (uid 911) |
| `SETUID` / `SETGID` | s6-overlay drops privileges from root to abc |
| `DAC_OVERRIDE` / `FOWNER` | Required by `s6-setuidgid` and the LSIO init scripts |

The Docker socket bind mount (`/var/run/docker.sock`) is the only host path needed and is only required for container-based jobs.

**Why this works:**

- `read_only: true` blocks any writes to the image's root filesystem.
- The runner install is at `/opt/runner-bin` (immutable, lives in the image).
- An init step at startup populates `/opt/actions-runner` (tmpfs) with
  hard links to `/opt/runner-bin/*` (or full copies when the runtime is on
  a different filesystem, e.g. tmpfs), leaving room for runtime state files
  (`.runner`, `.credentials`, `_diag/`, `_work/`) on the tmpfs.
  Hard links — not symlinks — are used because `Runner.Listener` resolves
  `/proc/self/exe` to the real path; symlinks would cause it to write
  state into the read-only `/opt/runner-bin` tree.
- No `/config` host volume is mounted: ephemeral runners discard state every
  run, so `/config` lives on a tmpfs and is wiped between container lifetimes
  by design.
- `stop_grace_period: 30s` ≥ `S6_KILL_GRACETIME` ≥ finish-script timeout
  ensures `config.sh remove` completes so the runner doesn't linger as
  *offline* in GitHub. **Set this explicitly** — Docker's default is only
  `10s`, which will SIGKILL the container mid-deregister and leave a stale
  runner in the GitHub UI on every restart.
- Setting `DISABLE_RUNNER_UPDATE=true` is recommended: in ephemeral +
  read-only mode any auto-update is lost when the tmpfs is recycled.

> **Note:** `PUID`/`PGID` and Docker Mods are ignored when `read_only: true`.
> The container always runs as the LSIO `abc` user (uid 911).

### docker-compose (persistent runner with /config volume)

```yaml
---
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    container_name: gh-runner-org
    environment:
      - TZ=Etc/UTC
      - RUNNER_URL=https://github.com/MY-ORG
      - RUNNER_TOKEN=YOUR_ORG_REGISTRATION_TOKEN
      - RUNNER_NAME=org-runner-01
      - RUNNER_GROUP=production
      - RUNNER_LABELS=self-hosted,linux,x64,docker
    volumes:
      - /path/to/runner/config:/config
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:mode=1777
    restart: unless-stopped
```

### docker-cli ([click here for more info](https://docs.docker.com/engine/reference/commandline/cli/))

```bash
docker run -d \
  --name=gh-runner \
  -e TZ=Etc/UTC \
  -e RUNNER_URL=https://github.com/OWNER/REPO \
  -e RUNNER_TOKEN=YOUR_REGISTRATION_TOKEN \
  -e RUNNER_NAME=my-runner \
  -v /path/to/runner/config:/config \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --security-opt no-new-privileges:true \
  --restart unless-stopped \
  blackoutsecure/docker-github-runner:latest
```

### Multiple Runners

Run multiple runners on the same host using `docker compose --scale`. Each container gets a unique hostname, and the runner auto-deduplicates names (appending `-1`, `-2`, etc. if an online runner with the same name already exists).

```yaml
---
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    # No container_name — required for scaling
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_YourPATHere
      - RUNNER_LABELS=self-hosted
      - RUNNER_EPHEMERAL=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:mode=1777
      - /config
    restart: always
```

```bash
# Start 3 identical runners
docker compose up -d --scale gh-runner=3
```

For per-runner control over labels and groups, define explicit services:

```yaml
---
services:
  gh-runner-1:
    image: blackoutsecure/docker-github-runner:latest
    container_name: gh-runner-1
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_YourPATHere
      - RUNNER_NAME=gh-runner-1
      - RUNNER_LABELS=self-hosted,large
      - RUNNER_EPHEMERAL=true
    volumes:
      - runner-config-1:/config
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:mode=1777
    restart: always

  gh-runner-2:
    image: blackoutsecure/docker-github-runner:latest
    container_name: gh-runner-2
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_YourPATHere
      - RUNNER_NAME=gh-runner-2
      - RUNNER_LABELS=self-hosted,small
      - RUNNER_EPHEMERAL=true
    volumes:
      - runner-config-2:/config
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:mode=1777
    restart: always

volumes:
  runner-config-1:
  runner-config-2:
```

### Autoscaling

For dynamic scaling based on runner load, use the included autoscaler script. It monitors runner busy/idle status via the GitHub API and scales the runner service between a minimum and maximum replica count.

```yaml
---
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_YourPATHere
      - RUNNER_LABELS=self-hosted
      - RUNNER_EPHEMERAL=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:mode=1777
      - /config
    restart: always

  gh-runner-scaler:
    image: docker.io/docker/compose:latest
    entrypoint: ["/bin/bash", "/scripts/autoscale.sh"]
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_YourPATHere
      - SCALE_MIN=1
      - SCALE_MAX=5
      - SCALE_MODE=auto        # auto or fixed
      - SCALE_INTERVAL=30      # seconds between checks
      - SCALE_COOLDOWN=60      # seconds between scale events
      - SCALE_UP_THRESHOLD=80  # scale up when ≥80% busy
      - SCALE_DOWN_THRESHOLD=20 # scale down when ≤20% busy
      - COMPOSE_SERVICE=gh-runner
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./scripts:/scripts:ro
    restart: always
    depends_on:
      - gh-runner
```

**Scaling modes:**

| Mode | Behavior |
| --- | --- |
| `auto` | Scales between `SCALE_MIN` and `SCALE_MAX` based on busy runner ratio |
| `fixed` | Always maintains exactly `SCALE_MAX` runners (self-heals if one dies) |

**For a fixed number of runners** (no dynamic scaling), set `SCALE_MODE=fixed` and `SCALE_MAX` to the desired count, or simply use `--scale`:

```bash
docker compose up -d --scale gh-runner=3
```

#### Concurrency model in ephemeral mode

`RUNNER_EPHEMERAL=true` makes the upstream `Runner.Listener` single-shot:
each container picks up **exactly one job**, runs it, and exits. With
`restart: always` the container then comes back up and re-registers as a
brand-new runner. There is no upstream knob for "N jobs per listener" in
ephemeral mode — that's how `--ephemeral` is defined by GitHub.

> **One ephemeral container = capacity for one concurrent job.**
> Concurrency on a host comes from running multiple replicas, not from
> anything inside a single container.

If you need *N* jobs to run at the same time, you need *N* replicas (via
`docker compose up --scale gh-runner=N` or via the autoscaler's
`SCALE_MAX=N`). If you need persistent multi-job capacity from a single
container instead, drop `RUNNER_EPHEMERAL` (the listener will then accept
back-to-back jobs serially — but still only one at a time, by upstream
design).

**Graceful scale-down (autoscaler):** Because each ephemeral container
is mid-job for ~100% of its life, a naive `compose --scale=N-1` would
remove a container in compose's index order and could abort an
in-flight workflow. The autoscaler avoids this:

1. Queries the GitHub API for runners that are `online` AND `busy=false`.
2. Resolves each idle runner name → local container (the runner registers
   under its container hostname when `RUNNER_NAME` is unset).
3. `docker stop`s only those idle containers, so the s6 finish hook runs
   a clean `config.sh remove` and Docker honours the stop intent (no
   restart).
4. Reconciles compose's view of the replica count.

If no idle runners are available at scale-down time, the autoscaler
**defers** the scale-in and tries again next interval rather than
aborting a busy job. This makes scale-down slower under sustained
load — by design.

## Parameters

### Environment Variables

| Parameter | Default | Description | Required |
| --- | --- | --- | --- |
| `-e TZ=Etc/UTC` | `Etc/UTC` | Timezone (TZ database) | Optional |
| `-e RUNNER_URL=` | | GitHub repository, organization, or enterprise URL | **Required** |
| `-e RUNNER_URL_FILE=` | | Path to file containing `RUNNER_URL` (Docker secrets) | Alternative |
| `-e RUNNER_TOKEN=` | | Runner registration token from GitHub (expires in 1h) | **Required**\* |
| `-e RUNNER_TOKEN_FILE=` | | Path to file containing `RUNNER_TOKEN` (Docker secrets) | Alternative |
| `-e GITHUB_PAT=` | | GitHub PAT — auto-generates registration tokens via API | **Required**\* |
| `-e GITHUB_PAT_FILE=` | | Path to file containing `GITHUB_PAT` (Docker secrets) | Alternative |
| `-e GITHUB_TOKEN=` | | Repo secret or GitHub App token — auto-generates registration tokens | **Required**\* |
| `-e GITHUB_TOKEN_FILE=` | | Path to file containing `GITHUB_TOKEN` (Docker secrets) | Alternative |
| `-e RUNNER_NAME=` | hostname | Runner display name (auto-deduplicated if taken) | Optional |
| `-e RUNNER_LABELS=` | `self-hosted` | Comma-separated custom labels | Optional |
| `-e RUNNER_GROUP=` | `Default` | Runner group (org-level only) | Optional |
| `-e RUNNER_WORKDIR=` | `/config/work` | Job working directory | Optional |
| `-e RUNNER_EPHEMERAL=` | `false` | Exit after one job (for autoscaling) | Optional |
| `-e RUNNER_REPLACE_EXISTING=` | `true` | Replace existing runner with same name | Optional |
| `-e DISABLE_RUNNER_UPDATE=` | `false` | Disable automatic runner version updates | Optional |
| `-e RUNNER_ENV_FILE=` | | Path to env file (`KEY=VALUE` per line) injected into runner jobs | Optional |
| `-e RUNNER_SECRETS_DIR=` | | Path to directory of secret files (filename=var, contents=value) | Optional |
| `-e LOG_LEVEL=` | `info` | Container log verbosity: `debug`, `info`, `warn`, `error`, `fatal` (`fatal` always shown) | Optional |
| `-e EXTRA_PACKAGES=` | | Space-separated apt packages to install before the runner starts (escape hatch — see notes) | Optional |
| `-e EXTRA_APT_REPOS=` | | Semicolon-separated extra apt sources to add before installing `EXTRA_PACKAGES` | Optional |
| `-e EXTRA_INIT_SCRIPT=` | | Path to a shell script (typically bind-mounted) executed as root before the runner starts | Optional |
| `-e DOCKER_IN_DOCKER=` | `false` | Enable container-based jobs by binding the runner user to the gid that owns the mounted `/var/run/docker.sock`; auto-appends a `docker` runner label | Optional |
| `-e ONLINE_PROBE_EVERY=` | `1` | Verify runner is online with GitHub every N heartbeats (~2 min each); `0` disables | Optional |
| `-e ONLINE_FAIL_THRESHOLD=` | `3` | Consecutive offline detections before triggering `ON_OFFLINE_ACTION` | Optional |
| `-e ON_OFFLINE_ACTION=` | `restart` | Action when offline threshold trips: `none` \| `restart` (s6) \| `shutdown` (container) | Optional |
| `-e HEALTH_STALE_AFTER=` | `300` | Seconds before the Docker `HEALTHCHECK` reports unhealthy if the online sentinel goes stale | Optional |
| `-e CLEANUP_OFFLINE_RUNNERS=` | `false` | Master toggle for the startup sweep that DELETEs offline runners from GitHub. Requires `GITHUB_PAT` / `GITHUB_TOKEN` | Optional |
| `-e CLEANUP_OFFLINE_AFTER=` | `86400` | **Seconds** a runner must have been continuously offline before removal in threshold mode (minimum `300` s = 5 min; default `86400` s = 24 h). Ignored when immediate mode is active | Optional |
| `-e CLEANUP_OFFLINE_IMMEDIATE=` | _auto_ | When `true`, bypass the offline-since timer and remove ANY currently-offline runner. Auto-resolves to `true` when `RUNNER_EPHEMERAL=true`, `false` otherwise. The runner this container is about to register is always skipped | Optional |
| `-e CLEANUP_OFFLINE_NAME_REGEX=` | | Optional ERE pattern; only runners whose names match are eligible for cleanup (e.g. `^aada` to scope to ephemeral hash-named runners) | Optional |
| `-e CLEANUP_OFFLINE_DRY_RUN=` | `false` | When `true`, log what would be removed without calling DELETE. Recommended for the first deploy | Optional |
| `-e CLEANUP_OFFLINE_MAX=` | `25` | **Maximum number of runners** (count, not a duration) that may be removed in a single startup sweep. Safety brake against an accidental mass-delete from a misconfigured regex | Optional |
| `-e S6_SERVICES_GRACETIME=` | `30000` | s6 service shutdown gracetime (ms) — must allow time for runner to deregister | Optional |
| `-e S6_KILL_GRACETIME=` | `30000` | s6 hard-kill gracetime (ms) — keep aligned with `stop_grace_period` | Optional |
| `-e PUID=1000` | `1000` | User ID for file ownership (ignored when `read_only: true`, runs as uid 911) | Optional |
| `-e PGID=1000` | `1000` | Group ID for file ownership (ignored when `read_only: true`) | Optional |

\* Provide **one** of `RUNNER_TOKEN`, `GITHUB_PAT`, or `GITHUB_TOKEN`. Priority: `RUNNER_TOKEN` > `GITHUB_PAT` > `GITHUB_TOKEN`.

### Autoscaler Variables

These variables are used by the `gh-runner-scaler` sidecar service (see [Autoscaling](#autoscaling)):

| Parameter | Default | Description |
| --- | --- | --- |
| `SCALE_MIN` | `1` | Minimum runners always running |
| `SCALE_MAX` | `1` | Maximum runners allowed |
| `SCALE_MODE` | `auto` | `auto` = scale on demand, `fixed` = always run `SCALE_MAX` |
| `SCALE_INTERVAL` | `30` | Seconds between scaling checks |
| `SCALE_COOLDOWN` | `60` | Seconds to wait between scale events |
| `SCALE_UP_THRESHOLD` | `80` | Scale up when ≥N% of runners are busy |
| `SCALE_DOWN_THRESHOLD` | `20` | Scale down when ≤N% of runners are busy |

### Storage Mounts

| Volume | Description | Recommendation |
| --- | --- | --- |
| `-v /config` | Runner configuration and persistent data | Recommended |
| `-v /var/run/docker.sock` | Docker socket for container actions | Optional |

## Configuration

Environment variables are set using `-e` flags in `docker run` or the `environment:` section in docker-compose.

### Generating a Registration Token

**Via the GitHub UI:**

1. Navigate to your repository or organization Settings
2. Go to Actions > Runners
3. Click "New self-hosted runner"
4. Copy the token from the configuration instructions

**Via the GitHub API:**

```bash
# Repository-level token
curl -X POST \
  -H "Authorization: token YOUR_GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/OWNER/REPO/actions/runners/registration-token \
  | jq -r '.token'

# Organization-level token
curl -X POST \
  -H "Authorization: token YOUR_GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/orgs/ORG/actions/runners/registration-token \
  | jq -r '.token'
```

> **Note:** Registration tokens expire after 1 hour. The runner only needs the token during initial registration — once configured, it uses its own credentials stored in `/config`.

### Using a GitHub PAT (recommended for production)

Instead of generating short-lived registration tokens manually, provide a **GitHub Personal Access Token** via `GITHUB_PAT`. The container calls the GitHub API on startup to auto-generate a registration token. This is the recommended approach for production — no manual token renewal needed.

**Required PAT permissions:**

| PAT Type | Scope (repo-level) | Scope (org-level) |
| --- | --- | --- |
| Classic | `repo` | `admin:org` |
| Fine-grained | `Administration` (read & write) | `Self-hosted runners` (read & write) |

**Supported `RUNNER_URL` formats:**

| Scope | URL Format | API Endpoint |
| --- | --- | --- |
| Repository | `https://github.com/OWNER/REPO` | `repos/OWNER/REPO/actions/runners/registration-token` |
| Organization | `https://github.com/ORG` | `orgs/ORG/actions/runners/registration-token` |
| Enterprise | `https://github.com/enterprises/ENT` | `enterprises/ENT/actions/runners/registration-token` |

**Example (env var):**

```bash
docker run -d \
  --name gh-runner \
  -e GITHUB_PAT=ghp_YourPersonalAccessTokenHere \
  -e RUNNER_URL=https://github.com/OWNER/REPO \
  -v runner-config:/config \
  blackoutsecure/docker-github-runner:latest
```

**Example (Docker secret):**

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    environment:
      - GITHUB_PAT_FILE=/run/secrets/github_pat
      - RUNNER_URL=https://github.com/OWNER/REPO
      - RUNNER_NAME=my-runner
    secrets:
      - github_pat
    volumes:
      - runner-config:/config
    restart: unless-stopped

secrets:
  github_pat:
    file: ./secrets/github_pat.txt
```

### Using a GitHub Repo Secret or App Token (`GITHUB_TOKEN`)

If you're deploying the runner container from a GitHub Actions workflow, you can pass a repo secret or a GitHub App installation token via `GITHUB_TOKEN`. This uses the same API as `GITHUB_PAT` but is scoped to the token's permissions.

**Common sources for `GITHUB_TOKEN`:**

| Source | Example | Notes |
| --- | --- | --- |
| Repo secret | `${{ secrets.RUNNER_PAT }}` | Store a PAT as a repo secret, pass it at deploy time |
| GitHub App token | `${{ steps.app-token.outputs.token }}` | Generated via `actions/create-github-app-token` |
| Workflow token | `${{ secrets.GITHUB_TOKEN }}` | Built-in, but usually lacks runner admin permissions |

> **Note:** The built-in `${{ secrets.GITHUB_TOKEN }}` in Actions workflows typically does **not** have permission to create runner registration tokens. Use a repo secret containing a PAT or a GitHub App installation token instead.

**Example — deploy runner from a GitHub Actions workflow:**

```yaml
# .github/workflows/deploy-runner.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy self-hosted runner
        run: |
          docker run -d \
            --name gh-runner \
            -e GITHUB_TOKEN=${{ secrets.RUNNER_PAT }} \
            -e RUNNER_URL=https://github.com/${{ github.repository }} \
            -e RUNNER_NAME=ci-runner-${{ github.run_id }} \
            -e RUNNER_EPHEMERAL=true \
            -v runner-config:/config \
            blackoutsecure/docker-github-runner:latest
```

**Priority order:** `RUNNER_TOKEN` > `GITHUB_PAT` > `GITHUB_TOKEN`. If `RUNNER_TOKEN` is already set, `GITHUB_PAT` and `GITHUB_TOKEN` are ignored.

### Using Docker Secrets (`_FILE` variables)

For production deployments, avoid passing secrets as plain-text environment variables. Instead, use `_FILE` variants that read the secret from a file:

| Variable | `_FILE` Alternative | Description |
| --- | --- | --- |
| `RUNNER_TOKEN` | `RUNNER_TOKEN_FILE` | Path to file containing the registration token |
| `RUNNER_URL` | `RUNNER_URL_FILE` | Path to file containing the repository/org URL |
| `GITHUB_PAT` | `GITHUB_PAT_FILE` | Path to file containing a GitHub PAT |
| `GITHUB_TOKEN` | `GITHUB_TOKEN_FILE` | Path to file containing a GitHub repo secret / app token |

The `_FILE` variable takes precedence if both the plain and `_FILE` versions are set.

**Docker Compose with secrets:**

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    environment:
      - GITHUB_PAT_FILE=/run/secrets/github_pat
      - RUNNER_URL_FILE=/run/secrets/runner_url
      - RUNNER_NAME=my-runner
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

**Docker CLI with file-based secrets:**

```bash
# Create secret files
mkdir -p secrets
echo "ghp_YourPATHere" > secrets/github_pat.txt
echo "https://github.com/OWNER/REPO" > secrets/runner_url.txt

docker run -d \
  --name gh-runner \
  -e GITHUB_PAT_FILE=/run/secrets/github_pat \
  -e RUNNER_URL_FILE=/run/secrets/runner_url \
  -v $(pwd)/secrets/github_pat.txt:/run/secrets/github_pat:ro \
  -v $(pwd)/secrets/runner_url.txt:/run/secrets/runner_url:ro \
  -v runner-config:/config \
  blackoutsecure/docker-github-runner:latest
```

### Injecting Custom Environment Secrets

To make your own GitHub repo secrets (or any custom env vars) available to runner jobs, use `RUNNER_ENV_FILE` or `RUNNER_SECRETS_DIR`. These are loaded at container startup and injected into the runner process environment, so every workflow job on this runner can access them.

#### Option 1: Env file (`RUNNER_ENV_FILE`)

Mount a file with `KEY=VALUE` pairs (one per line). Comments (`#`) and blank lines are ignored. Supports quoted values.

**From a GitHub Actions workflow:**

```yaml
# .github/workflows/deploy-runner.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Write secrets to env file
        run: |
          mkdir -p /tmp/runner-secrets
          cat > /tmp/runner-secrets/env << 'EOF'
          NPM_TOKEN=${{ secrets.NPM_TOKEN }}
          AWS_ACCESS_KEY_ID=${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY=${{ secrets.AWS_SECRET_ACCESS_KEY }}
          SONAR_TOKEN=${{ secrets.SONAR_TOKEN }}
          DOCKER_REGISTRY_PASSWORD=${{ secrets.DOCKER_REGISTRY_PASSWORD }}
          EOF

      - name: Deploy self-hosted runner
        run: |
          docker run -d \
            --name gh-runner \
            -e GITHUB_TOKEN=${{ secrets.RUNNER_PAT }} \
            -e RUNNER_URL=https://github.com/${{ github.repository }} \
            -e RUNNER_ENV_FILE=/run/secrets/env \
            -v /tmp/runner-secrets/env:/run/secrets/env:ro \
            -v runner-config:/config \
            blackoutsecure/docker-github-runner:latest
```

**With Docker Compose:**

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    environment:
      - GITHUB_PAT_FILE=/run/secrets/github_pat
      - RUNNER_URL=https://github.com/OWNER/REPO
      - RUNNER_ENV_FILE=/run/secrets/env
    secrets:
      - github_pat
    volumes:
      - ./secrets/runner.env:/run/secrets/env:ro
      - runner-config:/config
    restart: unless-stopped
```

Where `secrets/runner.env` contains:

```bash
# secrets/runner.env
NPM_TOKEN=npm_abc123
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=wJalr...
SONAR_TOKEN=sqp_abc123
```

#### Option 2: Secrets directory (`RUNNER_SECRETS_DIR`)

Mount a directory where each file is one secret — the filename becomes the env var name and the file contents become the value. This works natively with Docker Compose secrets and Kubernetes projected volumes.

**From a GitHub Actions workflow:**

```yaml
- name: Write individual secret files
  run: |
    mkdir -p /tmp/runner-secrets/dir
    echo -n "${{ secrets.NPM_TOKEN }}" > /tmp/runner-secrets/dir/NPM_TOKEN
    echo -n "${{ secrets.AWS_ACCESS_KEY_ID }}" > /tmp/runner-secrets/dir/AWS_ACCESS_KEY_ID
    echo -n "${{ secrets.AWS_SECRET_ACCESS_KEY }}" > /tmp/runner-secrets/dir/AWS_SECRET_ACCESS_KEY

- name: Deploy self-hosted runner
  run: |
    docker run -d \
      --name gh-runner \
      -e GITHUB_TOKEN=${{ secrets.RUNNER_PAT }} \
      -e RUNNER_URL=https://github.com/${{ github.repository }} \
      -e RUNNER_SECRETS_DIR=/run/secrets/custom \
      -v /tmp/runner-secrets/dir:/run/secrets/custom:ro \
      -v runner-config:/config \
      blackoutsecure/docker-github-runner:latest
```

**With Docker Compose secrets:**

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    environment:
      - GITHUB_PAT_FILE=/run/secrets/github_pat
      - RUNNER_URL=https://github.com/OWNER/REPO
      - RUNNER_SECRETS_DIR=/run/secrets/custom
    secrets:
      - github_pat
    volumes:
      - ./secrets/custom:/run/secrets/custom:ro
      - runner-config:/config
    restart: unless-stopped
```

Where `secrets/custom/` contains individual files:

```text
secrets/custom/
├── NPM_TOKEN          # contents: npm_abc123
├── AWS_ACCESS_KEY_ID  # contents: AKIA...
└── SONAR_TOKEN        # contents: sqp_abc123
```

#### Option 3: Direct `-e` flags (simplest)

For a small number of secrets, pass them directly:

```bash
docker run -d \
  --name gh-runner \
  -e GITHUB_PAT=${{ secrets.RUNNER_PAT }} \
  -e RUNNER_URL=https://github.com/OWNER/REPO \
  -e NPM_TOKEN=${{ secrets.NPM_TOKEN }} \
  -e AWS_ACCESS_KEY_ID=${{ secrets.AWS_ACCESS_KEY_ID }} \
  -v runner-config:/config \
  blackoutsecure/docker-github-runner:latest
```

> **Note:** All three options can be combined. Direct `-e` env vars are set first, then `RUNNER_ENV_FILE` values, then `RUNNER_SECRETS_DIR` values. Later values override earlier ones.

## Privileges Required by Feature

The image is designed to run with the **minimum** privileges that still let s6-overlay supervise the runner and drop it to the unprivileged `abc` user (uid 911). Enabling certain features requires additional privileges, capabilities, host setup, or mounts. Use this section to compose the smallest viable surface for your deployment.

### Minimum baseline (default config, no opt-in features)

This is what the image needs to start, register a runner, and execute shell-only jobs. Every other entry in the table below is **additive** on top of this baseline.

| Requirement | Value | Why |
| --- | --- | --- |
| Container user (PID 1) | `root` | s6-overlay init scripts and the runtime bootstrap need root before dropping to `abc` via `s6-setuidgid` |
| Linux capabilities | `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, `FOWNER` | Used by s6-overlay to chown `/run`, drop privileges, and respect file ownership |
| `security_opt` | `no-new-privileges=true` | Prevents any setuid/setgid binary inside the container from re-elevating |
| `cap_drop` | `ALL` (then re-add the five above) | Drops every capability not explicitly required |
| Filesystem | rootfs writable (default; not `read_only:true`) | Bootstrap hard-links `/opt/runner-bin` → `/opt/actions-runner` on the writable layer |
| Tmpfs | `/run`, `/tmp`, `/var/log` | s6 service state, job scratch, supervisor logs |
| Egress | `https://api.github.com`, `https://github.com`, `https://*.actions.githubusercontent.com` | Registration, listener long-poll, artifact / log upload |
| Required env | `RUNNER_URL` + one of `RUNNER_TOKEN` / `GITHUB_PAT` / `GITHUB_TOKEN` | Authenticates registration |

Hardened compose template matching this baseline:

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - RUNNER_TOKEN=ghr_xxx          # or GITHUB_PAT / GITHUB_TOKEN
    security_opt: [ "no-new-privileges=true" ]
    cap_drop: [ ALL ]
    cap_add: [ CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER ]
    tmpfs:
      - /run:exec,size=64m
      - /tmp:exec,size=64m,mode=1777
      - /var/log:size=32m
    restart: unless-stopped
```

### Per-feature privilege matrix

Each row lists the **additional** privileges required when the feature is enabled (i.e. on top of the baseline above).

| Feature / Variable | Extra container privilege | Extra Linux capability | Host requirement | Mount / volume requirement | GitHub token scope |
| --- | --- | --- | --- | --- | --- |
| `RUNNER_TOKEN` (registration only) | none | none | none | none | none (token already minted) |
| `GITHUB_PAT` / `GITHUB_TOKEN` (auto-mint) | none | none | none | none | classic: `repo` (repo) / `admin:org` (org); fine-grained: `Administration: write` (repo) or `Self-hosted runners: write` (org) |
| `RUNNER_EPHEMERAL=true` | none | none | none | none | same as registration |
| `DISABLE_RUNNER_UPDATE=true` | none | none | none | none | none |
| `AUTO_DOCKER_LABEL` | none | none | none | none | none |
| `LOG_LEVEL` | none | none | none | none | none |
| `RUNNER_ENV_FILE` | none | none | file readable by uid 911 inside the container | bind-mount the env file (read-only) | none |
| `RUNNER_SECRETS_DIR` | none | none | dir readable by uid 911 inside the container | bind-mount the secrets dir (read-only) | none |
| `EXTRA_PACKAGES` | container PID 1 = root (default) | none beyond baseline | none | rootfs writable (`read_only: false`); apt egress to Ubuntu mirrors | none |
| `EXTRA_APT_REPOS` | container PID 1 = root | none beyond baseline | none | rootfs writable; egress to the configured repos | none |
| `EXTRA_INIT_SCRIPT` | container PID 1 = root (script runs as root); rejected if world-writable | none beyond baseline | none | bind-mount the script (read-only recommended); script path **must not** be inside `/config`, `/tmp`, or any job-writable mount | none |
| `DOCKER_IN_DOCKER=true` (default model) | container PID 1 = root for the in-container `usermod` group fixup | none beyond baseline (the runner talks to the daemon over the unix socket; the daemon enforces) | engine socket on the host (`/var/run/docker.sock`, or Balena's `/var/run/balena-engine.sock`) | bind-mount the engine socket **or** use Balena `io.balena.features.balena-socket: '1'` label; rootfs writable so `/etc/group` can be updated | none |
| `DOCKER_IN_DOCKER=true` + `read_only: true` | none in-container, but the in-container fixup is blocked | none beyond baseline | one of: (a) `read_only: false`, (b) host-side `setfacl -m u:911:rw /var/run/docker.sock`, or (c) front the socket with [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) | engine socket bind-mount or proxy URL via `DOCKER_HOST` | none |
| `DOCKER_IN_DOCKER=true` + LSIO non-root (`user:`) | none in-container | none beyond baseline | the chosen uid must already be a member of the host docker group (use `user: "911:<docker-gid>"` or `group_add`) | engine socket bind-mount; tmpfs entries owned by the chosen uid (`/run:uid=911,gid=<gid>`) | none |
| `ONLINE_PROBE_EVERY` (process-only mode) | none | none | none | none | none |
| `ONLINE_PROBE_EVERY` (with API verification) | none | none | none | none | the same scope used for registration (`PAT`/`GITHUB_TOKEN` already configured) |
| `ON_OFFLINE_ACTION=restart` (default) | none | none | none | none | none |
| `ON_OFFLINE_ACTION=shutdown` | none | none | a container-level restart policy that respawns the container (`restart: always` / orchestrator) | none | none |
| `HEALTH_STALE_AFTER` (Docker `HEALTHCHECK`) | none | none | a Docker engine that honors `HEALTHCHECK` (engine ≥ 1.12) | none (sentinel lives in the existing `/run` tmpfs) | none |
| `CLEANUP_OFFLINE_RUNNERS=true` | none | none | none | persistent `/config` (named volume — a tmpfs wipes the offline-since timer on every restart) | classic: `repo` (repo) / `admin:org` (org); fine-grained: `Administration: write` (repo) or `Self-hosted runners: write` (org). DELETE on `/actions/runners/{id}` requires the same scope as registration |
| `CLEANUP_OFFLINE_*` (regex / dry-run / max) | none | none | none | none | inherited from `CLEANUP_OFFLINE_RUNNERS` |
| `read_only: true` (ephemeral hardened) | container PID 1 = root (still required for s6 init); `PUID`/`PGID` and Docker Mods are **ignored** | none beyond baseline | none | tmpfs at `/opt/actions-runner` (forces full copy bootstrap), `/config` (ephemeral state), in addition to baseline tmpfs entries | none |
| LSIO non-root mode (`user:` / `--user`) | container PID 1 = unprivileged uid; no privilege drop happens | none beyond baseline | host-side ownership of mounted volumes by the chosen uid | tmpfs at `/run` and others must be owned by the chosen uid (`uid=`/`gid=` mount opts); `EXTRA_PACKAGES` and apt-based init steps are silently skipped | none |
| `PUID` / `PGID` | container PID 1 = root (so LSIO base can `usermod`) | none beyond baseline | none | none | none |
| `S6_SERVICES_GRACETIME` / `S6_KILL_GRACETIME` / `stop_grace_period` | none | none | orchestrator must allow the configured grace (Compose `stop_grace_period`, Kubernetes `terminationGracePeriodSeconds`, etc.) | none | none |

### Notes on the columns

- **Extra container privilege** — anything beyond "unprivileged process inside the container". For most features the answer is "none in-container"; the privilege actually lives on the host (socket access, fs writability, etc.).
- **Extra Linux capability** — the baseline five (`CHOWN`/`SETUID`/`SETGID`/`DAC_OVERRIDE`/`FOWNER`) cover every supported feature; no opt-in feature requires re-adding any other capability. Notably **`NET_ADMIN`, `SYS_ADMIN`, `SYS_PTRACE` are never needed**.
- **Host requirement** — something the host operator must do (mount a socket, install ACLs, set a uid). Listed separately from container-side mounts because they're frequently the actual blocker.
- **Mount / volume requirement** — what `volumes:` / `tmpfs:` entries must exist for the feature to work as documented.
- **GitHub token scope** — the minimum PAT scope or fine-grained permission. "none" means the feature is purely local to the container and never calls the GitHub API.

### Choosing the smallest viable surface

A few common deployment shapes and the minimum settings for each:

| Goal | Privileges to add to baseline |
| --- | --- |
| Shell-only jobs against a private repo, manual token | nothing — baseline only |
| Same as above but auto-mint registration tokens | add `GITHUB_PAT` env (no extra container privilege) |
| Container-based jobs (Docker actions, service containers) | `DOCKER_IN_DOCKER=true` + bind-mount engine socket; rootfs writable (or use the read-only options above) |
| Ephemeral fleet with auto-cleanup | `RUNNER_EPHEMERAL=true` + `CLEANUP_OFFLINE_RUNNERS=true` + `GITHUB_PAT` + persistent `/config` volume |
| Maximum hardening (read-only, capability-minimized, ephemeral) | `read_only: true` + the ephemeral compose example in [Usage](#docker-compose-ephemeral-mode--autoscaling-read-only-hardened); accept the per-start copy cost |

### GitHub API privileges by variable

This is the **token-side** view of the matrix above: which variables cause the container to call the GitHub API, what HTTP verb / endpoint they call, and the minimum classic-PAT scope, fine-grained PAT permission, and GitHub App permission for each. Variables not listed here never call the GitHub API.

The "scope" depends on the registration target encoded in `RUNNER_URL`:

- Repository (`https://github.com/OWNER/REPO`) → `repos/{owner}/{repo}/...`
- Organization (`https://github.com/ORG`) → `orgs/{org}/...`
- Enterprise (`https://github.com/enterprises/{ENT}`) → `enterprises/{ent}/...`

| Variable / Feature | API call(s) made | Classic PAT scope | Fine-grained PAT permission | GitHub App permission |
| --- | --- | --- | --- | --- |
| `RUNNER_TOKEN` (you already minted it) | none from this container — `Runner.Listener` performs an **authenticated WebSocket session** to the Actions service using its post-registration credentials | none (token is already a registration token) | n/a | n/a |
| `GITHUB_PAT` / `GITHUB_TOKEN` — registration token mint | `POST /repos/{o}/{r}/actions/runners/registration-token`<br>`POST /orgs/{o}/actions/runners/registration-token`<br>`POST /enterprises/{e}/actions/runners/registration-token` | repo: `repo`<br>org: `admin:org`<br>enterprise: `manage_runners:enterprise` | repo: **Administration** = read & write<br>org: **Self-hosted runners** = read & write | repo: **Administration** = write<br>org: **Self-hosted runners** = write |
| Pre-flight token introspection | `GET /user` (one call, no impact on the runner once registered) | any token (classic or fine-grained) — used only to read `X-OAuth-Scopes` | any (no extra permission) | any (no extra permission) |
| Pre-flight scope probe | `GET /repos/{o}/{r}/actions/runners` etc. (HEAD-style sanity check) | same as registration | same as registration (read suffices, but write is required for the next step anyway) | same as registration |
| `ONLINE_PROBE_EVERY` (any value > 0) when a PAT is present — verify runner status with GitHub | `GET /repos/{o}/{r}/actions/runners` (paginated)<br>`GET /orgs/{o}/actions/runners` (paginated)<br>`GET /enterprises/{e}/actions/runners` (paginated) | repo: `repo`<br>org: `admin:org` (or `read:org`)<br>enterprise: `manage_runners:enterprise` | repo: **Administration** = read<br>org: **Self-hosted runners** = read | repo: **Administration** = read<br>org: **Self-hosted runners** = read |
| `RUNNER_GROUP` (org / enterprise only) — list / create runner group | `GET /orgs/{o}/actions/runner-groups`<br>`POST /orgs/{o}/actions/runner-groups` (only when group missing)<br>`GET /enterprises/{e}/actions/runner-groups`<br>`POST /enterprises/{e}/actions/runner-groups` | org: `admin:org`<br>enterprise: `manage_runners:enterprise` | org: **Self-hosted runners** = read & write | org: **Self-hosted runners** = write |
| `CLEANUP_OFFLINE_RUNNERS=true` — list candidates | same `GET .../actions/runners` calls as the online probe | same as online probe (read) | same as online probe (read) | same as online probe (read) |
| `CLEANUP_OFFLINE_RUNNERS=true` — delete offline runners | `DELETE /repos/{o}/{r}/actions/runners/{id}`<br>`DELETE /orgs/{o}/actions/runners/{id}`<br>`DELETE /enterprises/{e}/actions/runners/{id}` | repo: `repo`<br>org: `admin:org`<br>enterprise: `manage_runners:enterprise` | repo: **Administration** = read & write<br>org: **Self-hosted runners** = read & write | repo: **Administration** = write<br>org: **Self-hosted runners** = write |
| `CLEANUP_OFFLINE_DRY_RUN=true` | only the LIST call above, no DELETE | read-only equivalent of cleanup | read-only equivalent | read-only equivalent |
| `CLEANUP_OFFLINE_NAME_REGEX` / `CLEANUP_OFFLINE_AFTER` / `CLEANUP_OFFLINE_IMMEDIATE` / `CLEANUP_OFFLINE_MAX` | inherit from `CLEANUP_OFFLINE_RUNNERS` (no additional endpoints) | inherit | inherit | inherit |
| `RUNNER_LABELS` / `AUTO_*_LABELS` | none — labels are sent inline during `config.sh` registration | none beyond registration | none beyond registration | none beyond registration |
| All other variables (`RUNNER_EPHEMERAL`, `DISABLE_RUNNER_UPDATE`, `LOG_LEVEL`, `ON_OFFLINE_ACTION`, `HEALTH_STALE_AFTER`, `EXTRA_*`, `DOCKER_IN_DOCKER`, `S6_*`, `PUID`/`PGID`, `RUNNER_ENV_FILE`, `RUNNER_SECRETS_DIR`, `*_FILE`, `RUNNER_WORKDIR`, `RUNNER_REPLACE_EXISTING`) | none | none | none | none |

### Minimum-token cookbook

Pick the row that matches what you actually have enabled. Anything stricter than this is over-permissioned.

| Setup | Minimum classic PAT scope | Minimum fine-grained PAT permission |
| --- | --- | --- |
| Repo runner, `RUNNER_TOKEN` only | none (registration token is self-contained) | n/a |
| Repo runner, `GITHUB_PAT` for auto-mint **only** | `repo` | **Administration** = read & write (repo) |
| Repo runner, auto-mint + `ONLINE_PROBE_EVERY` (no cleanup) | `repo` | **Administration** = read & write (repo) |
| Repo runner, auto-mint + `CLEANUP_OFFLINE_RUNNERS` | `repo` | **Administration** = read & write (repo) |
| Org runner, `GITHUB_PAT` for auto-mint **only** | `admin:org` | **Self-hosted runners** = read & write (org) |
| Org runner, auto-mint + `RUNNER_GROUP` create-if-missing | `admin:org` | **Self-hosted runners** = read & write (org) |
| Org runner, auto-mint + cleanup + group + online probe | `admin:org` | **Self-hosted runners** = read & write (org) |
| Enterprise runner, full feature set | `manage_runners:enterprise` | not generally available — use a classic PAT or a GitHub App |

### Notes on token choice

- **`RUNNER_TOKEN`** is the cheapest from a privilege standpoint — it carries exactly the rights to register one runner and nothing else. It expires in 1 hour, so it's only useful for one-shot deploys or workflows that mint a fresh token immediately before `docker run`.
- **`GITHUB_PAT`** (a long-lived classic or fine-grained PAT) lives in the container for the entire lifetime of the deployment. Once the runner is registered, only `ONLINE_PROBE_EVERY`, `RUNNER_GROUP`, and `CLEANUP_OFFLINE_RUNNERS` continue to use it. If none of those features are enabled, you can opt to **delete the PAT from the env after first start** — the runner itself uses its own post-registration credentials in `/config/.credentials`.
- **`GITHUB_TOKEN`** sourced from a workflow's `${{ secrets.GITHUB_TOKEN }}` typically lacks the runner-admin permissions above. Use a repo-secret PAT or a GitHub App installation token (`actions/create-github-app-token`) instead.
- **GitHub App tokens** (installation tokens) work everywhere a PAT does, and they auto-rotate every hour. They're the recommended option for production fleets.

## User / Group Identifiers

By default, this container runs as the LSIO `abc` user (non-root) for better security isolation. The `abc` user is created by the [LinuxServer.io base image](https://docs.linuxserver.io/general/understanding-puid-and-pgid/) with UID/GID 911 and remapped at container start via `PUID`/`PGID`.

## Application Setup

The container runs the GitHub Actions self-hosted runner with s6 process supervision.

### Key Features

- **s6 Process Supervision**: The runner is managed by s6-overlay, with automatic restart on crash
- **Non-root Default**: Runs as the LSIO `abc` user for security isolation
- **Ephemeral Mode**: Set `RUNNER_EPHEMERAL=true` for single-job runners that auto-terminate (ideal for autoscaling)
- **Docker-in-Docker**: Mount the Docker socket for container-based GitHub Actions
- **Docker HEALTHCHECK**: Combines process liveness with an active GitHub-side online sentinel; marks the container unhealthy if the runner is disconnected from GitHub for too long
- **Auto-recovery on disconnect**: Heartbeat probes the GitHub API and triggers a graceful s6 restart (or container shutdown) if the runner stays offline beyond `ONLINE_FAIL_THRESHOLD`
- **Read-only friendly**: Ephemeral runners can be deployed with `read_only: true` (immutable runner install at `/opt/runner-bin`, runtime tmpfs at `/opt/actions-runner`). When you don't need read-only, leave `/opt/actions-runner` on the container's writable layer so the boot-time bootstrap can hard-link instead of copy — see [Cold-start performance](#cold-start-performance)
- **Automatic Registration**: Runner auto-configures on first start using `RUNNER_URL` and `RUNNER_TOKEN`
- **Persistent Configuration**: Runner credentials persist in `/config` across container restarts
- **Pre-installed Tools**: Includes git, docker CLI, python3, and common CI utilities

### Ephemeral Mode

Ephemeral runners accept exactly one job, execute it, then exit. This is ideal for:

- **Autoscaling**: Combine with container orchestration for elastic runner pools
- **Clean environments**: Every job gets a fresh runner with no state leakage
- **Security**: Reduces the attack surface by minimizing runner lifetime

```yaml
environment:
  - RUNNER_EPHEMERAL=true
restart: always  # Docker auto-restarts after each job
```

### Docker-in-Docker (container-based jobs)

To run container-based GitHub Actions (e.g. `jobs.<id>.container:`, service containers, or `uses: docker://image`), set `DOCKER_IN_DOCKER=true` **and** bind-mount the host's Docker socket:

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - DOCKER_IN_DOCKER=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: always
```

What happens when `DOCKER_IN_DOCKER=true`:

- The init step inspects the gid of `/var/run/docker.sock`, creates a matching group inside the container if one doesn't exist, and adds the `abc` user to it so non-root code in jobs can talk to the host Docker daemon.
- A `docker` label is auto-appended to `RUNNER_LABELS` so workflows can target the runner with `runs-on: [self-hosted, docker]`.
- A pre-flight check (`docker-in-docker`) verifies the socket is reachable and FAILS startup with a clear message if it isn't (e.g. socket missing, wrong perms).

**Default is `false`** because container-based jobs are an opt-in capability that grants the runner significant additional power on the host (see Security Note below).

#### DOCKER_IN_DOCKER + read-only mode

The group fixup needs to write to `/etc/group`, which a `read_only: true` rootfs blocks. You have three options when combining the two:

| Option | What to do |
| --- | --- |
| **A — Drop `read_only`** | Set `read_only: false` on this service. Simplest path. |
| **B — Pre-grant socket access on the host** | Run `sudo setfacl -m u:911:rw /var/run/docker.sock` on the host so uid 911 (the LSIO `abc` user) can use the socket without group membership. Survives container restarts; needs to be re-applied if the host's docker is reinstalled. |
| **C — Use a docker socket proxy** | Front the socket with [tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) and point the runner at the proxy via `DOCKER_HOST=tcp://proxy:2375`. No fs writes needed in the runner container. |

#### DOCKER_IN_DOCKER + non-root (`--user`) mode

**Yes, `DOCKER_IN_DOCKER=true` is supported with LSIO non-root mode** ([docs](https://docs.linuxserver.io/misc/non-root/)) — but the in-container group fixup is skipped (PID 1 isn't root, so it can't `usermod`). You must arrange access on the **host side** instead:

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    user: "911:999"               # 999 = the host's docker group gid (check with: getent group docker)
    group_add:
      - "999"                     # add additional supplementary groups if needed
    environment:
      - DOCKER_IN_DOCKER=true
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    tmpfs:
      - /run:uid=911,gid=999,exec,size=64m
      - /tmp:exec,size=64m,mode=1777
      - /opt/actions-runner:uid=911,gid=999,exec,size=512m
      - /config:uid=911,gid=999,exec,size=128m
    security_opt:
      - no-new-privileges=true
    restart: always
```

**How to find the right gid:** on the host, run `getent group docker | cut -d: -f3`. Use that value for the gid in `user:` (or in `group_add:`). The init step's pre-flight will FAIL with a clear message if the chosen uid still can't reach the socket.

> **Security Note**: Granting access to `/var/run/docker.sock` is equivalent to giving the container root on the host. Only enable `DOCKER_IN_DOCKER=true` on trusted infrastructure, and prefer a [socket proxy](https://github.com/Tecnativa/docker-socket-proxy) when running untrusted workflows.

### Custom packages and init scripts

The image runs an optional init oneshot **as root before** the runner service drops to the `abc` user, giving you a controlled hook to install extra tooling or run setup logic without rebuilding the image.

> **⚠ Security: production warning** — anything you put into `EXTRA_PACKAGES`, `EXTRA_APT_REPOS`, or `EXTRA_INIT_SCRIPT` runs **as root inside the container at every start**. In a CI runner that is also exposed to job code, treat these inputs as you would treat root credentials:
>
> - **Do not** populate them from untrusted sources (workflow inputs, repo secrets owned by external contributors, dynamic env files written by jobs, etc.).
> - **Do not** point `EXTRA_INIT_SCRIPT` at a path inside `/config`, `/tmp`, or anywhere a job can write to — a malicious job could replace the script before the next start.
> - Pin `EXTRA_APT_REPOS` to repositories you trust; an adversary controlling the repo can ship arbitrary post-install scriptlets.
> - For repeated production use, **build a custom image** (shown below) instead. It's reproducible, auditable in source control, and works with `read_only: true`.

**Built-in safeguards** (still — do not rely on these alone):

- All three vars are no-ops when unset or whitespace-only — the init step exits without touching apt or the filesystem.
- `EXTRA_PACKAGES` names are validated against `^[a-z0-9][a-z0-9+.\-]+$`; anything else aborts startup.
- `EXTRA_INIT_SCRIPT` is rejected if it's world-writable.
- Read-only rootfs is detected early and aborts cleanly with an actionable message.
- Non-root (`--user`) mode silently skips the apt steps with a warning rather than running them as the unprivileged user.

| Variable | Purpose |
| --- | --- |
| `EXTRA_PACKAGES` | Space-separated apt packages, e.g. `EXTRA_PACKAGES="ffmpeg awscli"` |
| `EXTRA_APT_REPOS` | Semicolon-separated apt sources lines added before installing |
| `EXTRA_INIT_SCRIPT` | Path to a shell script (typically bind-mounted **read-only**) run with `bash -e`. Rejected if world-writable. |

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - EXTRA_PACKAGES=ffmpeg awscli rsync
      - EXTRA_INIT_SCRIPT=/setup/install-tools.sh
    volumes:
      - ./setup:/setup:ro
      - /var/run/docker.sock:/var/run/docker.sock
    # NOTE: read_only must be FALSE when using EXTRA_PACKAGES
    # read_only: false
    restart: always
```

**Trade-offs:**

| Concern | Detail |
| --- | --- |
| **Speed** | Packages reinstall on every container start. In ephemeral mode that's once per job — slow. |
| **Read-only mode** | Incompatible. apt needs to write to `/var/lib/apt`, `/etc`, `/usr`. The init step refuses to run with a clear error if the rootfs is read-only. |
| **Security** | Package names are validated against `^[a-z0-9][a-z0-9+.\-]+$` to prevent shell injection from untrusted env vars. The init script runs as root — only point `EXTRA_INIT_SCRIPT` at scripts you control. |
| **Reproducibility** | Repeated installs can produce different results as upstream packages change. |

**Recommended alternative for repeated use** — build a thin custom image:

```dockerfile
FROM blackoutsecure/docker-github-runner:latest
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg awscli rsync \
 && rm -rf /var/lib/apt/lists/*
USER abc
```

A custom image takes 0 startup time, is reproducible, and works with `read_only: true`.

#### What else can I add via the init hook?

`EXTRA_INIT_SCRIPT` is intentionally a generic shell hook, so it covers most "I need to set up X before the runner starts" cases without us inventing new variables. Common additions people request:

| Need | How to do it |
| --- | --- |
| **Python packages** | `EXTRA_PACKAGES="python3-pip"` then `pip3 install --no-cache-dir foo bar` in `EXTRA_INIT_SCRIPT` |
| **Node.js global packages** | `EXTRA_PACKAGES="nodejs npm"` then `npm install -g pnpm yarn` in `EXTRA_INIT_SCRIPT` |
| **Custom CA certificates** (corporate proxy, private registry) | Bind-mount the cert into `/usr/local/share/ca-certificates/`, then `update-ca-certificates` in `EXTRA_INIT_SCRIPT` |
| **Pre-fetched build caches** | Bind-mount the cache into `/config/cache:ro`; reference it from your workflow |
| **Shell aliases / env for jobs** | Use `RUNNER_ENV_FILE` (already supported) — it's per-job, not container-wide |
| **Pre-job / post-job hooks** | Set the upstream `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` env vars to script paths — these are runner-native |
| **Private apt repository** | `EXTRA_APT_REPOS="deb [signed-by=/etc/apt/keyrings/foo.gpg] https://repo.example/ stable main"` + bind-mount the keyring |

If your need isn't covered by `EXTRA_PACKAGES` + `EXTRA_INIT_SCRIPT`, the right answer is almost always a custom Dockerfile. We deliberately don't add per-language wrapper variables (`EXTRA_PIP_PACKAGES`, `EXTRA_NPM_PACKAGES`, etc.) because they multiply surface area without giving you anything `EXTRA_INIT_SCRIPT` can't do, and they encourage running install commands on every container start where a custom image would be vastly faster and reproducible.

### Running as a non-root user (LSIO `--user`)

By default this image follows the standard LinuxServer.io model: the container starts as `root`, then s6 drops the runner service to the unprivileged `abc` user (uid 911). For most setups this is the right choice and gives you `PUID`/`PGID`, mods, and `EXTRA_PACKAGES` support.

If your security policy requires that the **container's PID 1 itself** runs unprivileged, you can opt in to LSIO's [non-root mode](https://docs.linuxserver.io/misc/non-root/) by setting `user:` on the service.

```yaml
services:
  gh-runner:
    image: blackoutsecure/docker-github-runner:latest
    user: "911:911"
    environment:
      - RUNNER_URL=https://github.com/OWNER/REPO
      - GITHUB_PAT=ghp_xxx
      - RUNNER_EPHEMERAL=true
    tmpfs:
      # /run MUST be owned by the user running the container so s6 can write
      # its service state. Required when combined with no-new-privileges.
      - /run:uid=911,gid=911,exec,size=64m
      - /tmp:exec,size=64m,mode=1777
      - /opt/actions-runner:uid=911,gid=911,exec,size=512m
      - /config:uid=911,gid=911,exec,size=128m
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges=true
    cap_drop:
      - ALL
    restart: always
```

**Caveats** (per the LSIO docs):

| Limitation | Detail |
| --- | --- |
| **`PUID`/`PGID` ignored** | The container runs as the uid/gid passed via `--user`. Pick a uid your mounted volumes already accept. |
| **`EXTRA_PACKAGES` ignored** | apt requires root. The init step warns and skips. Build a custom image instead. |
| **`EXTRA_INIT_SCRIPT` runs unprivileged** | Any root-only operation inside it will fail. |
| **`DOCKER_IN_DOCKER` requires host-side setup** | The in-container group fixup is skipped (no root). The chosen uid must already belong to a group with the host docker socket's gid — set `user: "911:<docker-gid>"` or use `group_add`. See the [DOCKER_IN_DOCKER + non-root](#docker_in_docker--non-root---user-mode) section. |
| **Mounted-volume permissions** | You manually manage permissions on bind mounts. |
| **`no-new-privileges=true`** | Requires `/run` tmpfs owned by the container's uid (shown above). |

This mode is supported on a reasonable-endeavours basis — the default model is the recommended path for most users.

## Stale Offline Runner Cleanup

Crashed or force-killed containers (SIGKILL, host reboot, power loss) skip the
`finish` deregistration hook and leave a runner registered as `offline` in
GitHub. Ephemeral fleets are particularly prone to accumulating these ghosts
because every job spawns a fresh container hostname / runner name.

The image can sweep them at startup via the GitHub API. Set
`CLEANUP_OFFLINE_RUNNERS=true` and provide `GITHUB_PAT` (or `GITHUB_TOKEN`) with
the same scope used to register runners (`admin:org` /
`manage_runners:enterprise` / repo `administration`). The sweep then runs once
per container start, right after pre-flight passes and before registration.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLEANUP_OFFLINE_RUNNERS` | `false` | Master toggle. The sweep is a no-op unless this is `true` and a token is available. |
| `CLEANUP_OFFLINE_IMMEDIATE` | _auto_ | When `true`, bypass the offline-since timer and remove ANY currently-offline runner. **Auto-resolves to `true` when `RUNNER_EPHEMERAL=true`** (offline ephemeral runners never reconnect, so no grace timer is meaningful) and `false` otherwise. Set explicitly to override. |
| `CLEANUP_OFFLINE_AFTER` | `86400` | **Seconds** a runner must be continuously offline before removal in threshold mode (minimum `300` s = 5 min; default `86400` s = 24 h). Persisted across restarts via `/config/.gh-runner-offline-state.json` so a brief reboot doesn't reset the timer. Ignored in immediate mode. |
| `CLEANUP_OFFLINE_NAME_REGEX` | _empty_ | Optional ERE pattern to scope the sweep (e.g. `^aada` to limit cleanup to ephemeral hash-named runners). |
| `CLEANUP_OFFLINE_DRY_RUN` | `false` | When `true`, log what would be removed without calling `DELETE`. **Recommended for the first deploy** so you can verify the victim list. |
| `CLEANUP_OFFLINE_MAX` | `25` | **Maximum number of runners** (a count, not a duration) that may be removed in a single startup sweep. Safety brake against an accidental mass-delete from a misconfigured regex. |

Built-in safety:

- The runner this container is **about to register** (`RUNNER_NAME`) is always
  excluded from the victim set, in both threshold and immediate modes.
- All deletions are logged with the runner name, id, and offline duration so the
  result is auditable in `docker logs gh-runner`.
- Pre-flight validates the regex (jq compile check), the threshold value, and
  `/config` writability before the sweep runs; failures abort container startup.

Recommended ephemeral fleet config:

```yaml
environment:
  - RUNNER_EPHEMERAL=true
  - GITHUB_PAT=ghp_xxx
  - CLEANUP_OFFLINE_RUNNERS=true
  # CLEANUP_OFFLINE_IMMEDIATE=true   # implicit when RUNNER_EPHEMERAL=true
  # CLEANUP_OFFLINE_DRY_RUN=true     # try this first
  - CLEANUP_OFFLINE_MAX=25
```

Recommended persistent fleet config (24 h grace before pruning):

```yaml
environment:
  - GITHUB_PAT=ghp_xxx
  - CLEANUP_OFFLINE_RUNNERS=true
  - CLEANUP_OFFLINE_AFTER=86400
  # CLEANUP_OFFLINE_IMMEDIATE=false  # implicit when RUNNER_EPHEMERAL=false
```

## Troubleshooting

### Container won't start or exits immediately

Check logs:

```bash
docker logs gh-runner
docker logs gh-runner --tail 50 -f
```

Common causes:

- **Missing RUNNER_URL**: Set the repository or organization URL
- **Invalid RUNNER_TOKEN**: Generate a fresh token (they expire after 1 hour)
- **Runner already registered**: Set `RUNNER_REPLACE_EXISTING=true` (default) or use a different `RUNNER_NAME`

### Runner appears offline in GitHub

- Verify the container is running: `docker ps | grep gh-runner`
- Check health status: `docker inspect --format='{{.State.Health.Status}}' gh-runner`
- Review runner logs for connection errors: `docker logs gh-runner 2>&1 | tail -20`

### Runner won't pick up jobs

- Confirm the runner is "Idle" in GitHub Settings > Actions > Runners
- Check label matching: your workflow's `runs-on` must match the runner's labels
- Verify the runner is assigned to the correct runner group (org-level)

### Slow container startup (multi-second gap before "Listening for Jobs")

The `init-gh-runner-config` step bootstraps the runner runtime tree from the
immutable `/opt/runner-bin` into `/opt/actions-runner`. If those two paths
live on different mounts (different `st_dev`), the kernel rejects `link()`
with `EXDEV` and the bootstrap falls back to a full recursive copy of
~200 MB of .NET runner binaries on every cold start. The container logs
name the cause and the elapsed milliseconds, e.g.

```
init-gh-runner-config[info]: Bootstrap: source /opt/runner-bin has 1543 file(s), 215000 KB total
init-gh-runner-config[warn]: Bootstrap: performing FULL FILE COPY of 215000 KB -- this is the dominant container start delay
init-gh-runner-config[info]: Bootstrap: copy of 1543 file(s) (215000 KB) completed in 8420 ms
```

**Common causes & fixes:**

| Cause | Fix |
| --- | --- |
| `tmpfs:` declared at `/opt/actions-runner` | Remove it. The container's writable layer is on the same fs as `/opt/runner-bin`, so the bootstrap can hard-link (~150 ms). Only keep the tmpfs when you actually need `read_only: true`. |
| Named volume mounted at `/opt/actions-runner` | Remove it. The runtime dir does not need to persist (registration files live in `/config`). |
| `read_only: true` | Inherent — the rootfs is immutable, the runtime dir must be a tmpfs, and the copy cannot be hard-linked. Mitigate by sizing the tmpfs adequately and pinning `APP_VERSION` so updates don't re-stretch it. |

The runtime is verified at startup: search the logs for `Bootstrap: ... mode: hardlink` (fast) vs `mode: copy` (slow), and the included device IDs / filesystem types tell you exactly which mount is on its own device.

## Cold-start performance

The biggest single contributor to container start latency is the bootstrap
of `/opt/actions-runner` from the immutable `/opt/runner-bin`. The init
step auto-detects whether the two paths share a filesystem and picks the
fastest viable strategy:

| Path layout | Bootstrap mode | Typical time |
| --- | --- | --- |
| `/opt/actions-runner` on the container's writable overlayfs | `hardlink` (cp -al) | ~100–200 ms |
| `/opt/actions-runner` on a tmpfs (e.g. `read_only: true`) | `copy` (cp -a) | ~3–15 s (size & disk-bound) |
| `/opt/actions-runner` on a docker volume | `copy` (cp -a) | ~3–15 s |

**Recommendations:**

- Do **not** mount a tmpfs or volume at `/opt/actions-runner` unless you
  have an explicit reason (read-only rootfs is the only common one).
  Ephemerality is already provided by `RUNNER_EPHEMERAL=true` + container
  recreate.
- Persist `/config` (named volume) when `CLEANUP_OFFLINE_RUNNERS=true` —
  the offline-since timestamps live in `/config/.gh-runner-offline-state.json`
  and a tmpfs there resets the cleanup timer on every restart.
- Use `RUNNER_TOKEN` directly (instead of `GITHUB_PAT`/`GITHUB_TOKEN`)
  when you can — it skips the registration-token mint round-trip.
- The pre-flight GitHub API calls run in parallel and complete in roughly
  one RTT to api.github.com.

## Health Monitoring

### Docker HEALTHCHECK

The image's `HEALTHCHECK` runs `/usr/local/bin/gh-runner-healthcheck`, which requires:

1. The `Runner.Listener` process must be alive.
2. The "online" sentinel at `/run/gh-runner/online` must have been refreshed within the last `HEALTH_STALE_AFTER` seconds (default 300).

The sentinel is refreshed by the heartbeat in `svc-gh-runner-logs`. When `GITHUB_PAT` (or `GITHUB_TOKEN`) is provided, the heartbeat verifies the runner shows as `online` via the GitHub API before refreshing — so a runner that's process-alive but disconnected from GitHub will go unhealthy. Without a token, the sentinel is refreshed whenever the listener process is alive (legacy behavior).

| Setting | Value |
| --- | --- |
| Interval | 30s |
| Timeout | 10s |
| Start period | 120s |
| Retries | 3 |

```bash
# Check container health status
docker inspect --format='{{.State.Health.Status}}' gh-runner
```

### Auto-recovery on disconnection

If the runner is reported `offline` by GitHub for `ONLINE_FAIL_THRESHOLD` consecutive heartbeats (~6 min by default), the container takes `ON_OFFLINE_ACTION`:

| Action | Behavior |
| --- | --- |
| `none` | Log only — let the Docker `HEALTHCHECK` and your orchestrator decide |
| `restart` *(default)* | Graceful restart of `svc-gh-runner` via `s6-svc -r` (keeps the container, re-registers the listener) |
| `shutdown` | Tear the container down — Docker's `restart: always` brings it back fresh |

### s6 Service Supervision

All services are supervised by s6-overlay and automatically restarted on crash:

```bash
# Check service status
docker exec gh-runner s6-svstat /run/service/svc-gh-runner
```

## Release & Versioning

This project uses [semantic versioning](https://semver.org/) tracking the upstream [actions/runner](https://github.com/actions/runner) releases:

- Releases published on [GitHub Releases](https://github.com/blackoutsecure/docker-github-runner/releases)
- Multi-arch images (amd64, arm64) built automatically
- Docker Hub tags: version-specific, `latest`, and architecture-specific
- Upstream release monitoring checks every 6 hours

Update to latest:

```bash
docker pull blackoutsecure/docker-github-runner:latest
docker-compose up -d  # if using compose
```

## Support & Getting Help

- Questions: [GitHub Issues](https://github.com/blackoutsecure/docker-github-runner/issues)
- Bug Reports: Include Docker version, container logs, and reproduction steps
- Upstream Documentation: [GitHub Actions Runner](https://github.com/actions/runner)
- Self-hosted runner docs: [GitHub Docs](https://docs.github.com/en/actions/hosting-your-own-runners)

## References

### Project Resources

| Resource | Link |
| --- | --- |
| Docker Hub | [blackoutsecure/docker-github-runner](https://hub.docker.com/r/blackoutsecure/docker-github-runner) |
| GitHub Issues | [Report bugs or request features](https://github.com/blackoutsecure/docker-github-runner/issues) |
| GitHub Releases | [Download releases](https://github.com/blackoutsecure/docker-github-runner/releases) |

### Upstream & Related

| Project | Link |
| --- | --- |
| GitHub Actions Runner | [actions/runner](https://github.com/actions/runner) |
| LinuxServer.io | [linuxserver.io](https://linuxserver.io) |
| Self-hosted Runner Docs | [GitHub Docs](https://docs.github.com/en/actions/hosting-your-own-runners) |

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

The GitHub Actions Runner application itself is licensed under the MIT License. For more information, see the [actions/runner repository](https://github.com/actions/runner).

---

Made with ❤️ by [Blackout Secure](https://blackoutsecure.app/)
