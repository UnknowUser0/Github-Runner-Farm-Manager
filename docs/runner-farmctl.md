# `runner-farmctl` Command Reference

Manager version: **v1.0.0**

Worker image version: **v1.0.0**

## TUI

Running the command without arguments opens the interactive terminal UI:

```bash
runner-farmctl
```

The TUI manages multiple repository and organization farms from one screen.

## `install <repo/org>`

Install a new independent runner farm:

```bash
runner-farmctl install OWNER/REPOSITORY
runner-farmctl install ORGANIZATION
```

URLs are also supported:

```bash
runner-farmctl install https://github.com/OWNER/REPOSITORY
runner-farmctl install https://github.com/ORGANIZATION
```

The first installation asks for GitHub authentication. Later installations reuse the saved authentication.

The installation flow asks for:

1. number of runners, default `4`;
2. per-runner resource mode;
3. custom CPU/RAM/swap values when custom mode is selected.

The default is `host/unlimited`.

## `list`

List every farm installed on this machine:

```bash
runner-farmctl list
```

Machine-readable instance IDs for completion/scripts:

```bash
runner-farmctl list --ids
```

## `status [target]`

Show all farms:

```bash
runner-farmctl status
```

Show one farm:

```bash
runner-farmctl status OWNER/REPOSITORY
runner-farmctl status <instance-id>
```

## `logs <target>`

Follow one farm's systemd logs:

```bash
runner-farmctl logs <target>
```

## `scale <target> <count>`

Change desired runner count:

```bash
runner-farmctl scale OWNER/REPOSITORY 8
```

When only one farm exists:

```bash
runner-farmctl scale 8
```

Scale-up creates missing slots. Scale-down removes idle excess workers and drains busy excess workers.

## `reconcile [target|--all]`

Wake the desired-state reconciler:

```bash
runner-farmctl reconcile <target>
runner-farmctl reconcile --all
```

## `sync [target|--all]`

Synchronize GitHub runner registrations with local worker containers:

```bash
runner-farmctl sync <target>
runner-farmctl sync --all
```

For registrations belonging to the selected farm:

- no matching local running container -> delete the GitHub registration;
- stale `Offline` registration -> delete it;
- local worker remains `Offline` beyond the configured grace period -> delete the registration and replace the container.

The farm uses a unique per-host/per-target runner prefix, so unrelated self-hosted runners are not removed.

## `limits <target> host`

Remove Docker CPU/RAM/swap limits:

```bash
runner-farmctl limits <target> host
```

This is the default.

## `limits <target> <cpu> <ram> [swap]`

Set per-runner limits:

```bash
runner-farmctl limits <target> 4 8G 4G
```

Validation:

- CPU must not exceed detected physical cores;
- RAM must not exceed host RAM;
- swap must not exceed host swap.

CPU topology is calculated from unique Linux `SOCKET,CORE` pairs rather than logical SMT threads. On virtual machines, this reflects topology exposed by the hypervisor.

Docker receives total memory+swap correctly:

```text
RAM  = 8G
Swap = 4G
--memory      = 8G
--memory-swap = 12G
```

## `labels <target> <labels>`

Set labels for newly spawned workers:

```bash
runner-farmctl labels <target> "universal,docker,java,node,android"
```

## `image-pull [target|--all]`

Pull configured worker images:

```bash
runner-farmctl image-pull <target>
runner-farmctl image-pull --all
```

## `start <target|--all>`

```bash
runner-farmctl start <target>
runner-farmctl start --all
```

## `stop <target|--all>`

```bash
runner-farmctl stop <target>
```

Stopping a farm can interrupt active jobs.

## `restart <target|--all>`

```bash
runner-farmctl restart <target>
```

Restarting can interrupt active jobs.

## `config <target>`

Show one target's local configuration:

```bash
runner-farmctl config <target>
```

Authentication is stored separately and is not printed by this command.

## Authentication commands

Show current authentication:

```bash
runner-farmctl auth status
```

Browser/device login:

```bash
runner-farmctl auth login
```

Save a PAT:

```bash
runner-farmctl auth pat
```

Remove saved authentication:

```bash
runner-farmctl auth logout
```

Authentication is global to the machine and reused across all installed farms.

## Completion commands

Install Bash, Zsh, and Fish completion definitions:

```bash
runner-farmctl completion install
```

Print one completion definition:

```bash
runner-farmctl completion bash
runner-farmctl completion zsh
runner-farmctl completion fish
```

The standard bootstrap installs completion automatically.

## `uninstall <target>`

Remove one farm:

```bash
runner-farmctl uninstall <target>
```

The manager and authentication remain installed.

Remove its configured local worker image too:

```bash
runner-farmctl uninstall <target> --purge-image
```

Force removal is reserved for cases where active work may be interrupted:

```bash
runner-farmctl uninstall <target> --force
```

## `self-uninstall`

Remove `runner-farmctl` itself:

```bash
runner-farmctl self-uninstall
```

All farms must be removed first.

## `version`

```bash
runner-farmctl version
```

Displays independent manager and image versions.

## Important paths

Global authentication:

```text
/etc/github-runner-farm/auth.env
```

Per-target configs:

```text
/etc/github-runner-farm/targets/<instance>.env
```

Supervisor:

```text
/usr/local/libexec/runner-farm-supervisor
```

Manager:

```text
/usr/local/bin/runner-farmctl
```

Systemd template:

```text
/etc/systemd/system/github-runner-farm@.service
```

Farm service:

```text
github-runner-farm@<instance>.service
```
