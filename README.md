# GitHub Runner Farm Manager

GitHub Runner Farm Manager manages multiple ephemeral self-hosted GitHub Actions runner farms on one Linux host. Each repository or organization is independent, with its own desired runner count, systemd service, container namespace, GitHub runner prefix, resource policy, labels, and reconciliation loop.

Authentication is stored once and reused by additional farms.

## Versions

Manager and worker image versions are intentionally separate:

```text
VERSION        -> runner-farmctl / manager version
IMAGE_VERSION  -> universal GHCR worker image version
```

Current v1 values:

```text
Manager: v1.0.0
Image  : v1.0.0
```

Default image:

```text
ghcr.io/skyteamexec/github-runner-farm-manager:v1.0.0
```

## Bootstrap installation

Install the manager and host prerequisites with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/SkyTeamExec/Github-Runner-Farm-Manager/main/install.sh | sh
```

The bootstrap does **not** create a farm and does not ask for a repository or organization. It prepares the host once by:

- validating Linux, linux/amd64, and systemd;
- installing small host dependencies through `apt-get`, `dnf`, `yum`, `pacman`, or `zypper`;
- installing Docker Engine automatically on Debian, Ubuntu, Fedora, RHEL, and CentOS when Docker is not already usable;
- keeping an existing Docker installation when `docker info` already succeeds;
- installing the official GitHub CLI Linux binary with SHA-256 checksum verification when `gh` is missing;
- installing `/usr/local/bin/runner-farmctl`;
- installing Bash, Zsh, and Fish completions.

For distributions where automatic Docker installation is intentionally not enabled, install Docker Engine using the distribution/vendor-supported method first and rerun the bootstrap.

After bootstrap, adding farms does not run the package manager and does not install Docker or GitHub CLI again. `runner-farmctl install` only validates that the prerequisites prepared by the bootstrap are still available.

Open the TUI:

```bash
runner-farmctl
```

Install a repository farm:

```bash
runner-farmctl install OWNER/REPOSITORY
```

Install an organization farm:

```bash
runner-farmctl install ORGANIZATION
```

GitHub URLs are also accepted.

## Authentication

The first farm installation asks for either GitHub browser/device login or a Personal Access Token. Later farm installations reuse the saved authentication.

```bash
runner-farmctl auth status
runner-farmctl auth login
runner-farmctl auth pat
runner-farmctl auth logout
```

The manager authentication file is stored at:

```text
/etc/github-runner-farm/auth.env
```

with root-only permissions.

## Multi-farm management

One host can manage several repositories and organizations at the same time:

```bash
runner-farmctl install UnknowUser0/Sky-Music
runner-farmctl install UnknowUser0/Backend-w4g
runner-farmctl install SkyTeamExec
```

List farms:

```bash
runner-farmctl list
```

Each farm has a separate target configuration and systemd service:

```text
/etc/github-runner-farm/targets/<instance>.env
github-runner-farm@<instance>.service
```

Stopping, restarting, scaling, or removing one farm does not remove other farm configurations.

## TUI

Run:

```bash
runner-farmctl
```

The TUI can list farms, install another target, inspect status, scale runners, edit resources, synchronize registrations, reconcile workers, show logs, start/stop/restart a farm, remove a farm, and inspect authentication.

The normal CLI remains available for scripting.

## Shell completion

Completion is installed automatically for Bash, Zsh, and Fish.

```bash
runner-farmctl completion install
```

Installed farm IDs are offered for commands that accept a farm target.

## Resource behavior

The default mode is:

```text
host/unlimited
```

No Docker CPU/RAM/swap limits are applied by default. Runners share the resources available on the host; this is not exclusive reservation.

For custom limits, CPU validation uses unique Linux `SOCKET,CORE` pairs instead of logical SMT threads. RAM cannot exceed host RAM and configured swap cannot exceed host swap.

Example:

```bash
runner-farmctl limits <target> 4 8G 4G
```

Docker receives:

```text
--cpus 4
--memory 8G
--memory-swap 12G
```

`--memory-swap` is RAM plus additional swap.

Return to host/unlimited mode:

```bash
runner-farmctl limits <target> host
```

## Scaling and synchronization

Scale a farm:

```bash
runner-farmctl scale <target> 8
runner-farmctl scale <target> 2
```

The supervisor creates missing slots, drains busy excess workers during scale-down, and replaces exited ephemeral workers when the desired count still requires them.

Manual local reconciliation:

```bash
runner-farmctl reconcile <target>
runner-farmctl reconcile --all
```

Manual GitHub runner synchronization:

```bash
runner-farmctl sync <target>
runner-farmctl sync --all
```

Each farm uses its own runner prefix so synchronization only targets registrations owned by that farm.

## Universal worker image

The worker image is an Ubuntu-based linux/amd64 CI environment with Docker-in-Docker and a broad toolchain including Git/GitHub CLI, Node.js, Bun, Deno, Java, Maven, Gradle, Python, Go, Rust, .NET, PHP, Ruby, Android SDK, database clients, kubectl, Helm, Terraform, AWS CLI, Chrome, ffmpeg, ImageMagick, protobuf, ShellCheck, and common build tools.

The host OS does not need to be Ubuntu. The runner workload is Ubuntu because it runs inside the universal worker container.

Each runner gets its own Docker daemon and does not mount the host `/var/run/docker.sock`.

The privileged Docker-in-Docker container provides separate workspace and Docker state between runners, but it should not be treated as equivalent to a virtual machine security boundary.

## Worker image CI

The large worker image is rebuilt automatically only for image-related changes:

```text
IMAGE_VERSION
docker/**
```

Manager/docs-only changes do not trigger the image build. `workflow_dispatch` remains available for manual image builds.

Published image tags include:

```text
v<IMAGE_VERSION>
v<IMAGE_MAJOR>
latest
sha-...
```

## Common commands

```bash
runner-farmctl
runner-farmctl install <repo/org>
runner-farmctl list
runner-farmctl status [target]
runner-farmctl logs <target>
runner-farmctl scale <target> <count>
runner-farmctl reconcile [target|--all]
runner-farmctl sync [target|--all]
runner-farmctl limits <target> host
runner-farmctl limits <target> <cpu> <ram> [swap]
runner-farmctl labels <target> <labels>
runner-farmctl image-pull [target|--all]
runner-farmctl start <target|--all]
runner-farmctl stop <target|--all]
runner-farmctl restart <target|--all]
runner-farmctl config <target>
runner-farmctl uninstall <target>
runner-farmctl uninstall --all
runner-farmctl manager-uninstall
runner-farmctl version
```

See [`docs/runner-farmctl.md`](docs/runner-farmctl.md) for the command reference.

## Uninstall

Remove one farm:

```bash
runner-farmctl uninstall <target>
```

The manager, saved authentication, and all other farms remain installed.

Remove that farm's configured worker image too:

```bash
runner-farmctl uninstall <target> --purge-image
```

Remove every farm but keep the manager:

```bash
runner-farmctl uninstall --all
```

Remove configured worker images too:

```bash
runner-farmctl uninstall --all --purge-image
```

To uninstall the manager itself, remove all farms first and then run:

```bash
runner-farmctl manager-uninstall
```

`manager-uninstall` removes the manager binary, supervisor, systemd service template, shell completion files, manager runtime/configuration data, and manager authentication. It deliberately does **not** uninstall Docker Engine, GitHub CLI, or other host packages installed during bootstrap because those may be used by unrelated software.

`runner-farmctl self-uninstall` remains available as a deprecated compatibility alias.
