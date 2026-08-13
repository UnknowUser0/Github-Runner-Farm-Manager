#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[worker:%s] %s\n' "${RUNNER_NAME:-unknown}" "$*"; }

: "${GITHUB_URL:?GITHUB_URL is required}"
: "${REGISTRATION_TOKEN:?REGISTRATION_TOKEN is required}"
: "${RUNNER_NAME:?RUNNER_NAME is required}"

RUNNER_LABELS="${RUNNER_LABELS:-universal,docker,java,node,python,go,rust,dotnet,android}"
RUNNER_DOWNLOAD_URL="${RUNNER_DOWNLOAD_URL:-}"
DOCKER_STORAGE_DRIVER="${DOCKER_STORAGE_DRIVER:-overlay2}"
DOCKER_READY_TIMEOUT="${DOCKER_READY_TIMEOUT:-60}"

prepare_runner() {
  local baked_version target_version
  baked_version="$(cat /opt/actions-runner/.runner-version 2>/dev/null || true)"
  target_version=""

  if [[ -n "$RUNNER_DOWNLOAD_URL" ]]; then
    target_version="$(sed -nE 's#.*actions-runner-linux-[^-]+-([0-9.]+)\.tar\.gz.*#\1#p' <<<"$RUNNER_DOWNLOAD_URL")"
  fi

  rm -rf /runner
  mkdir -p /runner

  if [[ -n "$target_version" && -n "$baked_version" && "$target_version" != "$baked_version" ]]; then
    log "GitHub exposes runner $target_version for this target; the image contains $baked_version. Downloading the target version for compatibility."
    curl -fsSL "$RUNNER_DOWNLOAD_URL" -o /tmp/actions-runner.tar.gz
    tar -xzf /tmp/actions-runner.tar.gz -C /runner
    rm -f /tmp/actions-runner.tar.gz
  else
    cp -a /opt/actions-runner/. /runner/
  fi

  mkdir -p /runner/_work /opt/hostedtoolcache /home/runner/.cache
  chown -R runner:runner /runner /opt/hostedtoolcache /home/runner
}

start_docker() {
  local driver="$1" i
  log "Starting isolated Docker daemon with storage driver: $driver"
  rm -f /var/run/docker.pid /var/run/docker.sock

  dockerd \
    --host=unix:///var/run/docker.sock \
    --storage-driver="$driver" \
    --data-root=/var/lib/docker \
    --exec-root=/var/run/docker-exec \
    --pidfile=/var/run/docker.pid \
    --log-level=error \
    >/var/log/dockerd.log 2>&1 &
  DOCKERD_PID=$!

  for ((i=1; i<=DOCKER_READY_TIMEOUT; i++)); do
    if docker info >/dev/null 2>&1; then
      chmod 0660 /var/run/docker.sock
      chown root:docker /var/run/docker.sock
      return 0
    fi
    if ! kill -0 "$DOCKERD_PID" 2>/dev/null; then
      return 1
    fi
    sleep 1
  done
  return 1
}

prepare_runner
mkdir -p /var/lib/docker /var/run

if ! start_docker "$DOCKER_STORAGE_DRIVER"; then
  log "Docker storage driver '$DOCKER_STORAGE_DRIVER' failed; falling back to vfs."
  if [[ -n "${DOCKERD_PID:-}" ]]; then
    kill "$DOCKERD_PID" 2>/dev/null || true
    wait "$DOCKERD_PID" 2>/dev/null || true
  fi
  rm -rf /var/lib/docker/* /var/run/docker-exec/* 2>/dev/null || true
  start_docker vfs || {
    cat /var/log/dockerd.log >&2 || true
    exit 70
  }
fi

log "Docker daemon ready: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"

cd /runner
runuser -u runner --preserve-environment -- ./config.sh \
  --unattended \
  --ephemeral \
  --replace \
  --url "$GITHUB_URL" \
  --token "$REGISTRATION_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work _work

unset REGISTRATION_TOKEN
export HOME=/home/runner
export USER=runner
export LOGNAME=runner
export DOCKER_HOST=unix:///var/run/docker.sock
export RUNNER_TOOL_CACHE=/opt/hostedtoolcache
export AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

log "Runner is online. This ephemeral worker exits after one job completes."
exec runuser -u runner --preserve-environment -- ./run.sh
