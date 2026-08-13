#!/bin/sh
set -eu

REPO="${RUNNER_FARM_REPO:-SkyTeamExec/Github-Runner-Farm-Manager}"
BRANCH="${RUNNER_FARM_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
CLI_URL="${BASE_URL}/runner-farmctl"
SUPERVISOR_URL="${BASE_URL}/runner-farm-supervisor"
DEST="/usr/local/bin/runner-farmctl"
SUPERVISOR_DEST="/usr/local/libexec/runner-farm-supervisor"
SERVICE_TEMPLATE="/etc/systemd/system/github-runner-farm@.service"

log() { printf '[runner-farm] %s\n' "$*"; }
die() { printf '[runner-farm] ERROR: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required to bootstrap runner-farmctl."
  SUDO="sudo"
fi

[ "$(uname -s)" = "Linux" ] || die "runner-farmctl requires a Linux host."
case "$(uname -m)" in
  x86_64|amd64) ;;
  *) die "The v1 worker image currently supports linux/amd64 only." ;;
esac
command -v systemctl >/dev/null 2>&1 || die "systemd is required by runner-farmctl v1."
[ -d /run/systemd/system ] || die "systemd is not running as PID 1 on this host."

os_id() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
  else
    printf 'unknown'
  fi
}

os_like() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s' "${ID_LIKE:-}"
  fi
}

detect_package_manager() {
  for pm in apt-get dnf yum pacman zypper; do
    if command -v "$pm" >/dev/null 2>&1; then
      printf '%s' "$pm"
      return 0
    fi
  done
  return 1
}

install_base_dependencies() {
  pm="$(detect_package_manager)" || die "No supported package manager was detected. Install curl, jq, util-linux, coreutils, ca-certificates, tar, and whiptail/newt manually, then rerun the bootstrap."
  log "Installing host dependencies with $pm..."
  case "$pm" in
    apt-get)
      $SUDO apt-get update
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq gnupg systemd util-linux coreutils tar whiptail
      ;;
    dnf)
      $SUDO dnf install -y ca-certificates curl jq gnupg2 systemd util-linux coreutils tar newt
      ;;
    yum)
      $SUDO yum install -y ca-certificates curl jq gnupg2 systemd util-linux coreutils tar newt
      ;;
    pacman)
      $SUDO pacman -Sy --needed --noconfirm ca-certificates curl jq gnupg systemd util-linux coreutils tar libnewt
      ;;
    zypper)
      $SUDO zypper --non-interactive refresh
      $SUDO zypper --non-interactive install ca-certificates curl jq gpg2 systemd util-linux coreutils tar newt
      ;;
  esac

  for cmd in curl jq lscpu numfmt awk sort sha256sum tar whiptail; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' is unavailable after dependency installation."
  done
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
    if $SUDO docker info >/dev/null 2>&1; then
      log "Using the existing Docker Engine installation."
      return
    fi
  fi

  id="$(os_id)"
  like="$(os_like)"
  case "$id" in
    ubuntu|debian|fedora|rhel|centos) ;;
    *)
      die "Docker Engine is not available and automatic Docker installation is not enabled for '$id'. Install Docker Engine for this distribution, verify 'docker info' succeeds, then rerun this bootstrap. Detected ID_LIKE: ${like:-none}."
      ;;
  esac

  log "Installing Docker Engine for $id..."
  docker_script="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$docker_script"
  $SUDO sh "$docker_script"
  rm -f "$docker_script"
  $SUDO systemctl enable --now docker
  $SUDO docker info >/dev/null 2>&1 || die "Docker Engine was installed but 'docker info' still fails."
}

install_github_cli() {
  if command -v gh >/dev/null 2>&1; then
    log "Using the existing GitHub CLI installation."
    return
  fi

  tmpdir="$(mktemp -d)"
  release_json="$tmpdir/release.json"
  trap 'rm -rf "$tmpdir"' 0 2 15

  log "Installing the official GitHub CLI Linux binary..."
  curl -fsSL -H 'Accept: application/vnd.github+json' https://api.github.com/repos/cli/cli/releases/latest -o "$release_json"
  tag="$(jq -r '.tag_name // empty' "$release_json")"
  case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) die "Could not resolve the latest GitHub CLI release." ;;
  esac

  version="${tag#v}"
  archive="gh_${version}_linux_amd64.tar.gz"
  checksums="gh_${version}_checksums.txt"
  curl -fL "https://github.com/cli/cli/releases/download/${tag}/${archive}" -o "$tmpdir/$archive"
  curl -fL "https://github.com/cli/cli/releases/download/${tag}/${checksums}" -o "$tmpdir/$checksums"

  expected="$(awk -v file="$archive" '$2 == file {print $1; exit}' "$tmpdir/$checksums")"
  [ "${#expected}" -eq 64 ] || die "The GitHub CLI release checksum was not found."
  printf '%s  %s\n' "$expected" "$tmpdir/$archive" | sha256sum -c - >/dev/null || die "GitHub CLI checksum verification failed."

  tar -xzf "$tmpdir/$archive" -C "$tmpdir"
  $SUDO install -m 0755 "$tmpdir/gh_${version}_linux_amd64/bin/gh" /usr/local/bin/gh
  /usr/local/bin/gh --version >/dev/null 2>&1 || die "GitHub CLI installation failed."
  rm -rf "$tmpdir"
  trap - 0 2 15
}

install_manager_runtime() {
  tmp_cli="$(mktemp)"
  tmp_supervisor="$(mktemp)"
  trap 'rm -f "$tmp_cli" "$tmp_supervisor"' 0 2 15

  log "Installing runner-farmctl and supervisor..."
  curl -fsSL "$CLI_URL" -o "$tmp_cli"
  curl -fsSL "$SUPERVISOR_URL" -o "$tmp_supervisor"
  chmod 0755 "$tmp_cli" "$tmp_supervisor"

  $SUDO install -d -m 0755 /usr/local/libexec
  $SUDO install -m 0755 "$tmp_cli" "$DEST"
  $SUDO install -m 0755 "$tmp_supervisor" "$SUPERVISOR_DEST"

  rm -f "$tmp_cli" "$tmp_supervisor"
  trap - 0 2 15

  service_tmp="$(mktemp)"
  cat > "$service_tmp" <<'EOF_SERVICE'
[Unit]
Description=GitHub Runner Farm (%i)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Environment=id=%i
ExecStart=/usr/local/libexec/runner-farm-supervisor %i
Restart=always
RestartSec=3
KillMode=mixed
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  $SUDO install -m 0644 "$service_tmp" "$SERVICE_TEMPLATE"
  rm -f "$service_tmp"
  $SUDO systemctl daemon-reload

  $SUDO "$DEST" completion install
}

install_base_dependencies
install_docker
install_github_cli
install_manager_runtime

log "Bootstrap completed."
"$DEST" version
printf '\nHost prerequisites and manager runtime are ready. No farm was created.\n\nOpen the TUI:\n  runner-farmctl\n\nInstall a farm:\n  runner-farmctl install <repo/org>\n\nExamples:\n  runner-farmctl install SkyTeamExec/Github-Runner-Farm-Manager\n  runner-farmctl install SkyTeamExec\n\nRemove one farm:\n  runner-farmctl uninstall <farm>\n\nRemove all farms but keep the manager:\n  runner-farmctl uninstall --all\n\nUninstall runner-farmctl itself (after farms are removed):\n  runner-farmctl manager-uninstall\n'
