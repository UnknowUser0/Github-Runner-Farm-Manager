# GitHub Runner Farm Manager

GitHub Runner Farm Manager manages multiple **ephemeral self-hosted GitHub Actions runner farms** on one Ubuntu host.

Each repository or organization is managed as an independent farm with its own:

- desired runner count;
- systemd service;
- container namespace;
- GitHub runner prefix;
- CPU/RAM/swap policy;
- labels;
- reconciliation loop.

Authentication is stored once on the host and reused for every farm.

## Versions

Manager/CLI and worker image versions are intentionally independent:

```text
VERSION        -> runner-farmctl / manager version
IMAGE_VERSION  -> GHCR universal worker image version
```

Current initial release:

```text
Manager: v1.0.0
Image  : v1.0.0
```

Default image:

```text
ghcr.io/skyteamexec/github-runner-farm-manager:v1.0.0
```

A manager-only change does not require rebuilding the worker image.

## Install the manager

```bash
curl -fsSL https://raw.githubusercontent.com/SkyTeamExec/Github-Runner-Farm-Manager/main/install.sh | sh
```

The bootstrap installs:

```text
/usr/local/bin/runner-farmctl
```

and Bash, Zsh, and Fish command completion definitions.

It does **not** create a GitHub runner farm yet.

Open the TUI:

```bash
runner-farmctl
```

Or install directly from the CLI:

```bash
runner-farmctl install SkyTeamExec/Github-Runner-Farm-Manager
```

Organization example:

```bash
runner-farmctl install SkyTeamExec
```

URLs are also accepted:

```bash
runner-farmctl install https://github.com/OWNER/REPOSITORY
runner-farmctl install https://github.com/ORGANIZATION
```

## Authentication

The first farm installation asks for one of:

```text
1. GitHub browser/device login
2. Personal Access Token (PAT)
```

Authentication is stored globally for this host and reused when additional repositories or organizations are installed.

Manage authentication explicitly:

```bash
runner-farmctl auth status
runner-farmctl auth login
runner-farmctl auth pat
runner-farmctl auth logout
```

Browser/device login uses GitHub CLI. PAT mode stores the token in:

```text
/etc/github-runner-farm/auth.env
```

with root-only permissions.

## Multiple repositories and organizations

One host can manage multiple targets at the same time:

```bash
runner-farmctl install UnknowUser0/Sky-Music
runner-farmctl install UnknowUser0/Backend-w4g
runner-farmctl install SkyTeamExec
```

List all installed farms:

```bash
runner-farmctl list
```

Each target receives a unique instance ID and a dedicated systemd service:

```text
github-runner-farm@<instance>.service
```

Target configs are stored separately:

```text
/etc/github-runner-farm/targets/<instance>.env
```

## TUI

Run the command without arguments:

```bash
runner-farmctl
```

The TUI can:

- list installed farms;
- install another repository or organization;
- inspect status;
- scale a farm;
- change CPU/RAM/swap settings;
- synchronize GitHub registrations;
- reconcile local workers;
- show logs;
- start/stop/restart a farm;
- remove a farm;
- inspect authentication.

The normal CLI remains available for scripting and users who prefer commands.

## Shell completion

The bootstrap installs completion for:

- Bash;
- Zsh;
- Fish.

It completes subcommands and installed farm instance IDs.

Reinstall completion files manually:

```bash
runner-farmctl completion install
```

## Runner resources

The default resource mode is:

```text
host/unlimited
```

No Docker `--cpus`, `--memory`, or `--memory-swap` limits are applied. Each runner may use the resources currently available on the host. Resources are shared between concurrent runners; they are not exclusively reserved.

During custom configuration, the manager displays:

- physical cores;
- logical CPUs/threads;
- RAM;
- swap.

CPU validation uses unique Linux `SOCKET,CORE` pairs rather than logical SMT threads. A requested per-runner CPU value greater than the detected physical-core count is rejected.

On a VM, the manager can only validate the CPU topology exposed by the hypervisor; it cannot see the physical topology of the underlying host.

RAM cannot exceed host RAM, and configured swap cannot exceed host swap.

Example:

```bash
runner-farmctl limits <target> 4 8G 4G
```

This becomes:

```text
--cpus 4
--memory 8G
--memory-swap 12G
```

`--memory-swap` is correctly calculated as RAM + swap.

Return to unrestricted mode:

```bash
runner-farmctl limits <target> host
```

Resource changes apply to newly spawned ephemeral workers and do not intentionally terminate current jobs.

## Scaling

```bash
runner-farmctl scale <target> 8
runner-farmctl scale <target> 2
```

If exactly one farm is installed, the target can be omitted:

```bash
runner-farmctl scale 8
```

The supervisor is desired-state based:

- missing slots are spawned automatically;
- idle excess slots are removed during scale-down;
- busy excess runners are drained;
- exited ephemeral workers are removed and replaced when still desired.

## GitHub runner synchronization

Each farm continuously reconciles **local containers and GitHub runner registrations**.

A runner registration belongs to a farm only when its name starts with that farm's unique host+target prefix.

The synchronization process:

- removes a farm registration that has no matching local running container;
- removes stale `Offline` registrations;
- replaces a local worker that stays `Offline` past the grace period;
- prevents old registrations from accumulating when an ephemeral container crashes;
- does not touch self-hosted runners created outside this farm prefix.

Manual synchronization:

```bash
runner-farmctl sync <target>
```

Synchronize every installed farm:

```bash
runner-farmctl sync --all
```

This specifically prevents states such as an old `s2` runner remaining `Offline` while a newer `s2` runner is already active.

## Universal Ubuntu worker

The v1 worker image targets Ubuntu/Linux AMD64 and includes one broad toolchain image rather than separate language images.

Included tooling covers:

- Docker Engine, Compose v2, Buildx;
- Git, Git LFS, GitHub CLI;
- Java 17 and Java 21;
- Maven and Gradle;
- Node.js 24 LTS, npm, pnpm, Yarn/Corepack;
- Bun and Deno;
- Python 3, pip, pipx;
- Go stable;
- Rust stable, Cargo, rustfmt, Clippy;
- .NET 10;
- PHP and Composer;
- Ruby and Bundler;
- GCC/G++, Clang/LLVM, CMake, Ninja, Meson;
- Android SDK, platform-tools/ADB, API 36, Build Tools 36.0.0;
- PostgreSQL, MySQL, Redis clients;
- kubectl, Helm, Terraform, AWS CLI v2, yq;
- Google Chrome;
- ffmpeg, ImageMagick, protobuf compiler, ShellCheck, and common Linux utilities.

Each worker runs a private Docker daemon. The host Docker socket is not shared with workflow jobs.

## Worker image CI

The worker image workflow runs automatically only when image-related files change:

```text
IMAGE_VERSION
docker/**
```

Changes to:

```text
README.md
docs/**
runner-farmctl
runner-farm-supervisor
install.sh
VERSION
```

do not rebuild the large worker image.

The workflow can still be started manually with `workflow_dispatch`.

Published tags include:

```text
v<IMAGE_VERSION>
v<IMAGE_MAJOR>
latest
sha-...
```

## Common commands

```bash
runner-farmctl
runner-farmctl list
runner-farmctl status
runner-farmctl status <target>
runner-farmctl logs <target>
runner-farmctl scale <target> <count>
runner-farmctl reconcile <target>
runner-farmctl sync <target>
runner-farmctl limits <target> host
runner-farmctl limits <target> <cpu> <ram> [swap]
runner-farmctl labels <target> <labels>
runner-farmctl image-pull <target>
runner-farmctl start <target>
runner-farmctl stop <target>
runner-farmctl restart <target>
runner-farmctl config <target>
runner-farmctl uninstall <target>
runner-farmctl version
```

See [`docs/runner-farmctl.md`](docs/runner-farmctl.md) for the full command reference.

## Remove one farm

```bash
runner-farmctl uninstall <target>
```

Remove its local image too:

```bash
runner-farmctl uninstall <target> --purge-image
```

The manager and saved authentication remain installed so another farm can be created immediately.

Remove the manager itself only after all farms have been removed:

```bash
runner-farmctl self-uninstall
```

## Security model

Workers use privileged Docker-in-Docker for broad Docker/Compose compatibility and strong separation of workspace, cache, and Docker state between runner containers.

A privileged container is **not** a VM-grade security boundary. Do not treat this design as safe for arbitrary hostile public pull-request code without an additional VM/microVM boundary.
