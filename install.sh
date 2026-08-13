#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_VERSION="1.0.0"
MANAGER_REPO="SkyTeamExec/Github-Runner-Farm-Manager"
INSTALL_DIR="${INSTALL_DIR:-/opt/github-runner-farm}"
IMAGE_NAME="${IMAGE_NAME:-ghcr.io/skyteamexec/github-runner-farm-manager:v${MANAGER_VERSION}}"
SERVICE_NAME="github-runner-farm"
CTL_PATH="/usr/local/bin/runner-farmctl"
API_VERSION="2026-03-10"

log() { printf '\033[1;34m[runner-farm]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[runner-farm]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[runner-farm]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Jalankan script sebagai root/sudo."
}

validate_positive_int() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name harus berupa integer > 0. Nilai: $value"
}

check_host() {
  [[ -r /etc/os-release ]] || die "Tidak dapat membaca /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "v1.0.0 fokus pada Ubuntu Linux. Host terdeteksi: ${ID:-unknown}."
  case "${VERSION_ID:-}" in
    22.04|24.04|26.04) ;;
    *) warn "Ubuntu ${VERSION_ID:-unknown} belum menjadi target uji utama v1.0.0; installer akan tetap mencoba." ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "Image v1.0.0 saat ini hanya tersedia untuk linux/amd64. Arsitektur host: $(uname -m)." ;;
  esac
}

install_host_dependencies() {
  log "Memasang dependency host..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl jq gnupg lsb-release systemd
}

install_github_cli() {
  if command -v gh >/dev/null 2>&1; then
    return
  fi

  log "Memasang GitHub CLI untuk login browser/device flow..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y gh
}

install_docker_host() {
  if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    if docker info >/dev/null 2>&1; then
      log "Docker Engine host sudah tersedia."
      return
    fi
  fi

  log "Memasang Docker Engine dari repository resmi Docker..."
  # shellcheck disable=SC1091
  . /etc/os-release
  local codename="${VERSION_CODENAME:-}"
  [[ -n "$codename" ]] || die "VERSION_CODENAME Ubuntu tidak ditemukan."

  apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc 2>/dev/null || true
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$codename" > /etc/apt/sources.list.d/docker.list

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker info >/dev/null
}

preliminary_scope_from_url() {
  local raw path rest
  raw="$1"
  raw="${raw%%\?*}"
  raw="${raw%%#*}"
  raw="${raw%/}"
  [[ "$raw" == https://github.com/* ]] || { printf 'unknown'; return; }
  path="${raw#https://github.com/}"
  path="${path#/}"
  case "$path" in
    organizations/*|orgs/*) printf 'org' ;;
    */*)
      rest="${path#*/}"
      if [[ -n "$rest" && "$rest" != */* ]]; then printf 'repo'; else printf 'unknown'; fi
      ;;
    *) printf 'org' ;;
  esac
}

github_web_login() {
  install_github_cli
  local prelim scopes
  prelim="$(preliminary_scope_from_url "$GITHUB_URL")"
  scopes="repo,read:packages"
  [[ "$prelim" == "org" ]] && scopes="repo,admin:org,read:packages"

  if gh auth status --hostname github.com >/dev/null 2>&1; then
    log "GitHub CLI sudah login; memastikan scope yang dibutuhkan..."
    gh auth refresh --hostname github.com --scopes "$scopes" || \
      die "Gagal memperbarui scope GitHub CLI. Gunakan mode PAT bila akun/policy organization tidak mengizinkan OAuth flow ini."
  else
    log "Membuka GitHub web/device authentication. Ikuti URL dan kode yang ditampilkan GitHub CLI."
    gh auth login \
      --hostname github.com \
      --git-protocol https \
      --web \
      --skip-ssh-key \
      --scopes "$scopes"
  fi

  GITHUB_PAT="$(gh auth token --hostname github.com)"
  [[ -n "$GITHUB_PAT" ]] || die "GitHub CLI login berhasil tetapi token tidak dapat dibaca."
  AUTH_METHOD="web"
}

collect_auth() {
  GITHUB_PAT="${GITHUB_PAT:-${GH_TOKEN:-}}"
  AUTH_METHOD="${AUTH_METHOD:-}"

  if [[ -n "$GITHUB_PAT" ]]; then
    AUTH_METHOD="${AUTH_METHOD:-token}"
    return
  fi

  [[ -t 0 ]] || die "Mode non-interaktif membutuhkan GITHUB_PAT atau GH_TOKEN."

  local choice
  read -r -p "Authentication [web/pat] (default: web): " choice
  choice="${choice:-web}"
  case "$choice" in
    web)
      github_web_login
      ;;
    pat|token)
      read -r -s -p "GitHub PAT: " GITHUB_PAT
      printf '\n'
      [[ -n "$GITHUB_PAT" ]] || die "PAT tidak boleh kosong."
      AUTH_METHOD="pat"
      ;;
    *) die "Authentication method tidak dikenal: $choice" ;;
  esac
}

github_api_get_status() {
  local url="$1" out="$2"
  curl -sS -o "$out" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "$url" || true
}

configure_repo_target() {
  local owner="$1" repo="$2" tmp code body
  repo="${repo%.git}"
  [[ -n "$owner" && -n "$repo" && "$owner" != */* && "$repo" != */* ]] || die "Target repository tidak valid."

  tmp="$(mktemp)"
  code="$(github_api_get_status "https://api.github.com/repos/${owner}/${repo}" "$tmp")"
  if [[ "$code" != "200" ]]; then
    body="$(cat "$tmp")"
    rm -f "$tmp"
    die "GitHub API tidak dapat mengakses repository ${owner}/${repo} (HTTP $code): $body"
  fi
  rm -f "$tmp"

  GITHUB_SCOPE="repo"
  GITHUB_OWNER="$owner"
  GITHUB_REPO="$repo"
  GITHUB_URL="https://github.com/${owner}/${repo}"
  REGISTRATION_ENDPOINT="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"
  RUNNER_DOWNLOADS_ENDPOINT="https://api.github.com/repos/${owner}/${repo}/actions/runners/downloads"
  log "Target terdeteksi: repository ${owner}/${repo}"
}

configure_org_target() {
  local org="$1" tmp code body
  [[ -n "$org" && "$org" != */* ]] || die "Target organization tidak valid."

  tmp="$(mktemp)"
  code="$(github_api_get_status "https://api.github.com/orgs/${org}" "$tmp")"
  if [[ "$code" != "200" ]]; then
    body="$(cat "$tmp")"
    rm -f "$tmp"
    die "Organization '${org}' tidak dapat diverifikasi (HTTP $code): $body"
  fi
  rm -f "$tmp"

  GITHUB_SCOPE="org"
  GITHUB_OWNER="$org"
  GITHUB_REPO=""
  GITHUB_URL="https://github.com/${org}"
  REGISTRATION_ENDPOINT="https://api.github.com/orgs/${org}/actions/runners/registration-token"
  RUNNER_DOWNLOADS_ENDPOINT="https://api.github.com/orgs/${org}/actions/runners/downloads"
  log "Target terdeteksi: organization ${org}"
}

detect_github_target() {
  local raw path first rest
  raw="$GITHUB_URL"
  raw="${raw%%\?*}"
  raw="${raw%%#*}"
  raw="${raw%/}"

  [[ "$raw" == https://github.com/* ]] || die "GitHub URL harus berupa https://github.com/..."
  path="${raw#https://github.com/}"
  path="${path#/}"
  [[ -n "$path" ]] || die "GitHub URL tidak memiliki target."

  case "$path" in
    organizations/*)
      rest="${path#organizations/}"
      rest="${rest%/}"
      [[ -n "$rest" && "$rest" != */* ]] || die "URL organization tidak valid: $raw"
      configure_org_target "$rest"
      return
      ;;
    orgs/*)
      rest="${path#orgs/}"
      rest="${rest%/}"
      [[ -n "$rest" && "$rest" != */* ]] || die "URL organization tidak valid: $raw"
      configure_org_target "$rest"
      return
      ;;
  esac

  if [[ "$path" == */* ]]; then
    first="${path%%/*}"
    rest="${path#*/}"
    [[ -n "$first" && -n "$rest" && "$rest" != */* ]] || \
      die "Untuk repository gunakan https://github.com/OWNER/REPO."
    configure_repo_target "$first" "$rest"
  else
    configure_org_target "$path"
  fi
}

collect_config() {
  GITHUB_URL="${GITHUB_URL:-}"
  RUNNER_COUNT="${RUNNER_COUNT:-4}"
  RUNNER_MAX_SLOTS="${RUNNER_MAX_SLOTS:-64}"

  # Empty CPU/RAM means Docker receives no resource limit flags: every runner
  # can use the full resources that the host scheduler makes available.
  RUNNER_CPU="${RUNNER_CPU:-}"
  RUNNER_MEMORY="${RUNNER_MEMORY:-}"
  RUNNER_MEMORY_SWAP="${RUNNER_MEMORY_SWAP:-}"

  RUNNER_PIDS_LIMIT="${RUNNER_PIDS_LIMIT:-4096}"
  RUNNER_SHM_SIZE="${RUNNER_SHM_SIZE:-1g}"
  RUNNER_PREFIX="${RUNNER_PREFIX:-gha}"
  RUNNER_LABELS="${RUNNER_LABELS:-universal,docker,java,node,python,go,rust,dotnet,android,ubuntu}"
  RESTART_DELAY="${RESTART_DELAY:-2}"
  DOCKER_STORAGE_DRIVER="${DOCKER_STORAGE_DRIVER:-overlay2}"

  if [[ -z "$GITHUB_URL" ]]; then
    [[ -t 0 ]] || die "Set GITHUB_URL untuk mode non-interaktif."
    read -r -p "GitHub URL (repo/org, otomatis dideteksi): " GITHUB_URL
  fi

  collect_auth

  validate_positive_int RUNNER_COUNT "$RUNNER_COUNT"
  validate_positive_int RUNNER_MAX_SLOTS "$RUNNER_MAX_SLOTS"
  validate_positive_int RUNNER_PIDS_LIMIT "$RUNNER_PIDS_LIMIT"
  (( RUNNER_COUNT <= RUNNER_MAX_SLOTS )) || die "RUNNER_COUNT melebihi RUNNER_MAX_SLOTS=$RUNNER_MAX_SLOTS."

  log "Mendeteksi repository/organization melalui GitHub API..."
  detect_github_target

  local path
  path="${GITHUB_URL#https://github.com/}"
  INSTANCE_ID="$(printf '%s' "${GITHUB_SCOPE}-${path}" | tr '/:@.' '-' | tr -cd '[:alnum:]_-')"
}

check_github_auth() {
  log "Memvalidasi akses self-hosted runner..."
  local response http_code body token downloads
  response="$(mktemp)"
  http_code="$(curl -sS -o "$response" -w '%{http_code}' \
    -X POST \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "$REGISTRATION_ENDPOINT" || true)"
  body="$(cat "$response")"
  rm -f "$response"

  [[ "$http_code" == "201" ]] || die "GitHub menolak akses runner (HTTP $http_code): $body"
  token="$(jq -r '.token // empty' <<<"$body")"
  [[ -n "$token" ]] || die "Registration token tidak dikembalikan GitHub."

  downloads="$(curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "$RUNNER_DOWNLOADS_ENDPOINT")" || die "Gagal mengambil daftar GitHub runner binary."

  RUNNER_DOWNLOAD_URL="$(jq -r '.[] | select(.os == "linux" and .architecture == "x64") | .download_url' <<<"$downloads" | head -n1)"
  [[ -n "$RUNNER_DOWNLOAD_URL" && "$RUNNER_DOWNLOAD_URL" != "null" ]] || die "GitHub tidak menyediakan runner Linux/x64 untuk target ini."
  log "Akses runner valid."
}

pull_worker_image() {
  log "Menarik universal worker image: $IMAGE_NAME"
  if docker pull "$IMAGE_NAME"; then
    return
  fi

  warn "Anonymous pull gagal. Mencoba autentikasi GHCR menggunakan token yang tersedia..."
  local token="${GHCR_TOKEN:-$GITHUB_PAT}" user
  user="$(curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    https://api.github.com/user | jq -r '.login // empty' || true)"

  if [[ -n "$token" && -n "$user" ]] && printf '%s' "$token" | docker login ghcr.io -u "$user" --password-stdin >/dev/null 2>&1; then
    docker pull "$IMAGE_NAME" && return
  fi

  die "Gagal pull $IMAGE_NAME. Pastikan workflow GHCR sudah sukses dan package dapat dibaca. Jika package private, set GHCR_TOKEN ke PAT classic dengan read:packages atau ubah package menjadi public."
}

write_config() {
  install -d -m 0700 "$INSTALL_DIR"
  local cfg="$INSTALL_DIR/config.env"
  umask 077
  {
    printf 'MANAGER_VERSION=%q\n' "$MANAGER_VERSION"
    printf 'MANAGER_REPO=%q\n' "$MANAGER_REPO"
    printf 'AUTH_METHOD=%q\n' "$AUTH_METHOD"
    printf 'GITHUB_SCOPE=%q\n' "$GITHUB_SCOPE"
    printf 'GITHUB_URL=%q\n' "$GITHUB_URL"
    printf 'GITHUB_PAT=%q\n' "$GITHUB_PAT"
    printf 'GITHUB_OWNER=%q\n' "$GITHUB_OWNER"
    printf 'GITHUB_REPO=%q\n' "$GITHUB_REPO"
    printf 'REGISTRATION_ENDPOINT=%q\n' "$REGISTRATION_ENDPOINT"
    printf 'RUNNER_DOWNLOADS_ENDPOINT=%q\n' "$RUNNER_DOWNLOADS_ENDPOINT"
    printf 'RUNNER_DOWNLOAD_URL=%q\n' "$RUNNER_DOWNLOAD_URL"
    printf 'API_VERSION=%q\n' "$API_VERSION"
    printf 'INSTANCE_ID=%q\n' "$INSTANCE_ID"
    printf 'IMAGE_NAME=%q\n' "$IMAGE_NAME"
    printf 'RUNNER_COUNT=%q\n' "$RUNNER_COUNT"
    printf 'RUNNER_MAX_SLOTS=%q\n' "$RUNNER_MAX_SLOTS"
    printf 'RUNNER_CPU=%q\n' "$RUNNER_CPU"
    printf 'RUNNER_MEMORY=%q\n' "$RUNNER_MEMORY"
    printf 'RUNNER_MEMORY_SWAP=%q\n' "$RUNNER_MEMORY_SWAP"
    printf 'RUNNER_PIDS_LIMIT=%q\n' "$RUNNER_PIDS_LIMIT"
    printf 'RUNNER_SHM_SIZE=%q\n' "$RUNNER_SHM_SIZE"
    printf 'RUNNER_PREFIX=%q\n' "$RUNNER_PREFIX"
    printf 'RUNNER_LABELS=%q\n' "$RUNNER_LABELS"
    printf 'RESTART_DELAY=%q\n' "$RESTART_DELAY"
    printf 'DOCKER_STORAGE_DRIVER=%q\n' "$DOCKER_STORAGE_DRIVER"
  } > "$cfg"
  chmod 0600 "$cfg"
}

write_supervisor() {
  cat > "$INSTALL_DIR/supervisor.sh" <<'SUPERVISOR'
#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/github-runner-farm}"
# shellcheck disable=SC1091
source "$INSTALL_DIR/config.env"

log() { printf '[supervisor] %s\n' "$*"; }
declare -A SLOT_PIDS=()
SHUTTING_DOWN=false

cleanup() {
  [[ "$SHUTTING_DOWN" == "true" ]] && return
  SHUTTING_DOWN=true
  touch "$INSTALL_DIR/.stopping"
  log "Stopping runner farm..."
  local slot pid
  for slot in "${!SLOT_PIDS[@]}"; do
    pid="${SLOT_PIDS[$slot]}"
    kill "$pid" 2>/dev/null || true
  done
  docker ps -q \
    --filter 'label=io.sky.github-runner-farm=true' \
    --filter "label=io.sky.github-runner-farm.instance=${INSTANCE_ID}" \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
  wait 2>/dev/null || true
}
shutdown() {
  trap - TERM INT USR1
  cleanup
  exit 0
}
trap shutdown TERM INT
trap cleanup EXIT
trap ':' USR1

get_registration_token() {
  local body token
  body="$(curl -fsSL \
    -X POST \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "$REGISTRATION_ENDPOINT")" || return 1
  token="$(jq -r '.token // empty' <<<"$body")"
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

slot_loop() {
  local slot="$1" host_short token name rc
  host_short="$(hostname -s | tr -cd '[:alnum:]_-')"

  while true; do
    # shellcheck disable=SC1090
    source "$INSTALL_DIR/config.env"
    [[ ! -e "$INSTALL_DIR/.stopping" ]] || return 0
    if (( slot > RUNNER_COUNT )); then
      log "slot=$slot no longer desired; slot loop exits"
      return 0
    fi

    token=""
    until token="$(get_registration_token)"; do
      # shellcheck disable=SC1090
      source "$INSTALL_DIR/config.env"
      (( slot <= RUNNER_COUNT )) || return 0
      log "slot=$slot gagal mengambil registration token; retry 15s"
      sleep 15
    done

    # shellcheck disable=SC1090
    source "$INSTALL_DIR/config.env"
    (( slot <= RUNNER_COUNT )) || return 0

    name="${RUNNER_PREFIX}-${host_short}-s${slot}-$(date +%s)-$RANDOM"
    log "slot=$slot starting $name image=$IMAGE_NAME"

    docker_args=(
      run --rm
      --name "$name"
      --hostname "$name"
      --privileged
      --pids-limit "$RUNNER_PIDS_LIMIT"
      --shm-size "$RUNNER_SHM_SIZE"
      --ulimit nofile=65535:65535
      --stop-timeout 30
      --label io.sky.github-runner-farm=true
      --label "io.sky.github-runner-farm.instance=${INSTANCE_ID}"
      --label "io.sky.github-runner-farm.slot=${slot}"
      -e "GITHUB_URL=${GITHUB_URL}"
      -e "REGISTRATION_TOKEN=${token}"
      -e "RUNNER_NAME=${name}"
      -e "RUNNER_LABELS=${RUNNER_LABELS}"
      -e "RUNNER_DOWNLOAD_URL=${RUNNER_DOWNLOAD_URL}"
      -e "DOCKER_STORAGE_DRIVER=${DOCKER_STORAGE_DRIVER}"
    )

    [[ -n "${RUNNER_CPU:-}" ]] && docker_args+=(--cpus "$RUNNER_CPU")
    [[ -n "${RUNNER_MEMORY:-}" ]] && docker_args+=(--memory "$RUNNER_MEMORY")
    [[ -n "${RUNNER_MEMORY_SWAP:-}" ]] && docker_args+=(--memory-swap "$RUNNER_MEMORY_SWAP")
    docker_args+=("$IMAGE_NAME")

    if docker "${docker_args[@]}"; then rc=0; else rc=$?; fi

    # shellcheck disable=SC1090
    source "$INSTALL_DIR/config.env"
    [[ ! -e "$INSTALL_DIR/.stopping" ]] || return 0
    if (( slot > RUNNER_COUNT )); then
      log "slot=$slot worker exited and slot is above desired count; no respawn"
      return 0
    fi

    log "slot=$slot runner=$name exited rc=$rc; fresh worker in ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY"
  done
}

start_slot_if_missing() {
  local slot="$1" pid="${SLOT_PIDS[$slot]:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return
  fi
  if [[ -n "$pid" ]]; then
    wait "$pid" 2>/dev/null || true
    unset 'SLOT_PIDS[$slot]'
  fi
  slot_loop "$slot" &
  SLOT_PIDS[$slot]=$!
  log "spawned slot loop $slot pid=${SLOT_PIDS[$slot]}"
}

rm -f "$INSTALL_DIR/.stopping"

docker ps -aq \
  --filter 'label=io.sky.github-runner-farm=true' \
  --filter "label=io.sky.github-runner-farm.instance=${INSTANCE_ID}" \
  | xargs -r docker rm -f >/dev/null 2>&1 || true

log "Supervisor online: desired=$RUNNER_COUNT max=$RUNNER_MAX_SLOTS target=$GITHUB_URL"

while true; do
  # shellcheck disable=SC1090
  source "$INSTALL_DIR/config.env"

  for slot in $(seq 1 "$RUNNER_COUNT"); do
    start_slot_if_missing "$slot"
  done

  for slot in "${!SLOT_PIDS[@]}"; do
    pid="${SLOT_PIDS[$slot]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      unset 'SLOT_PIDS[$slot]'
    fi
  done

  sleep 2 &
  wait $! 2>/dev/null || true
done
SUPERVISOR
  chmod 0700 "$INSTALL_DIR/supervisor.sh"
}

write_control_tool() {
  cat > "$CTL_PATH" <<'CTL'
#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/github-runner-farm}"
CFG="$INSTALL_DIR/config.env"
SERVICE="github-runner-farm"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
CTL_PATH="/usr/local/bin/runner-farmctl"

[[ -f "$CFG" ]] || { echo "Runner farm belum terpasang." >&2; exit 1; }
# shellcheck disable=SC1090
source "$CFG"

require_root() {
  [[ ${EUID} -eq 0 ]] || { echo "Command ini harus dijalankan dengan sudo/root." >&2; exit 1; }
}

set_cfg() {
  local key="$1" value="$2" escaped
  escaped="$(printf '%q' "$value")"
  if grep -q "^${key}=" "$CFG"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$CFG"
  else
    printf '%s=%s\n' "$key" "$escaped" >> "$CFG"
  fi
  chmod 0600 "$CFG"
}

signal_supervisor() {
  systemctl is-active --quiet "$SERVICE" || systemctl start "$SERVICE"
  systemctl kill --kill-who=main --signal=USR1 "$SERVICE" >/dev/null 2>&1 || true
}

github_runners_endpoint() {
  if [[ "$GITHUB_SCOPE" == "org" ]]; then
    printf 'https://api.github.com/orgs/%s/actions/runners' "$GITHUB_OWNER"
  else
    printf 'https://api.github.com/repos/%s/%s/actions/runners' "$GITHUB_OWNER" "$GITHUB_REPO"
  fi
}

farm_runner_name_prefix() {
  local host_short
  host_short="$(hostname -s | tr -cd '[:alnum:]_-')"
  printf '%s-%s-s' "$RUNNER_PREFIX" "$host_short"
}

list_farm_runners() {
  local endpoint prefix page tmp code count
  endpoint="$(github_runners_endpoint)"
  prefix="$(farm_runner_name_prefix)"
  page=1

  while true; do
    tmp="$(mktemp)"
    code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer ${GITHUB_PAT}" \
      -H "X-GitHub-Api-Version: ${API_VERSION}" \
      "${endpoint}?per_page=100&page=${page}" || true)"
    if [[ "$code" != "200" ]]; then
      echo "Gagal membaca runner GitHub (HTTP $code): $(cat "$tmp")" >&2
      rm -f "$tmp"
      return 1
    fi
    count="$(jq -r '.runners | length' "$tmp")"
    jq -c --arg prefix "$prefix" '.runners[] | select(.name | startswith($prefix))' "$tmp"
    rm -f "$tmp"
    (( count < 100 )) && break
    ((page++))
  done
}

delete_github_runner() {
  local id="$1" name="$2" endpoint tmp code
  endpoint="$(github_runners_endpoint)"
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' \
    -X DELETE \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "${endpoint}/${id}" || true)"
  case "$code" in
    204|404) echo "Deregistered: $name" ;;
    *)
      echo "Gagal menghapus runner '$name' id=$id (HTTP $code): $(cat "$tmp")" >&2
      rm -f "$tmp"
      return 1
      ;;
  esac
  rm -f "$tmp"
}

runner_slot_from_name() {
  sed -nE 's/.*-s([0-9]+)-[0-9]+-[0-9]+$/\1/p' <<<"$1"
}

live_slot_count() {
  docker ps \
    --filter 'label=io.sky.github-runner-farm=true' \
    --filter "label=io.sky.github-runner-farm.instance=${INSTANCE_ID}" \
    --format '{{.Label "io.sky.github-runner-farm.slot"}}' \
    | awk 'NF' | sort -nu | wc -l | tr -d ' '
}

wait_for_scale_up() {
  local desired="$1" timeout="${2:-30}" i live
  for ((i=1; i<=timeout; i++)); do
    live="$(live_slot_count)"
    if (( live >= desired )); then
      echo "Scale-up reconcile berhasil: live_slots=$live desired=$desired."
      return 0
    fi
    sleep 1
  done
  live="$(live_slot_count)"
  echo "Scale-up belum mencapai target setelah ${timeout}s: live_slots=$live desired=$desired." >&2
  echo "Periksa: runner-farmctl logs" >&2
  return 1
}

reconcile_scale_down() {
  local desired="$1" runners="$2"
  local cid slot name runner id busy stopped=0 draining=0 stale=0 current_runners="$runners"

  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    slot="$(docker inspect -f '{{ index .Config.Labels "io.sky.github-runner-farm.slot" }}' "$cid" 2>/dev/null || true)"
    [[ "$slot" =~ ^[0-9]+$ ]] || continue
    (( slot > desired )) || continue

    name="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || true)"
    [[ -n "$name" ]] || continue
    runner="$(printf '%s\n' "$current_runners" | jq -c --arg name "$name" 'select(.name == $name)' | head -n1)"

    if [[ -n "$runner" ]]; then
      busy="$(jq -r '.busy // false' <<<"$runner")"
      if [[ "$busy" == "true" ]]; then
        echo "Drain: slot $slot sedang busy ($name); job dibiarkan selesai dan slot tidak akan respawn."
        ((draining+=1))
        continue
      fi
    fi

    echo "Scale-down: menghentikan runner idle slot $slot ($name)..."
    docker stop --time 30 "$cid" >/dev/null 2>&1 || docker rm -f "$cid" >/dev/null 2>&1 || true
    ((stopped+=1))
    if [[ -n "$runner" ]]; then
      id="$(jq -r '.id' <<<"$runner")"
      delete_github_runner "$id" "$name" || return 1
    fi
  done < <(
    docker ps -q \
      --filter 'label=io.sky.github-runner-farm=true' \
      --filter "label=io.sky.github-runner-farm.instance=${INSTANCE_ID}"
  )

  current_runners="$(list_farm_runners)" || return 1
  while IFS= read -r runner; do
    [[ -n "$runner" ]] || continue
    name="$(jq -r '.name' <<<"$runner")"
    slot="$(runner_slot_from_name "$name")"
    [[ "$slot" =~ ^[0-9]+$ ]] || continue
    (( slot > desired )) || continue
    busy="$(jq -r '.busy // false' <<<"$runner")"
    [[ "$busy" == "true" ]] && continue
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
      continue
    fi
    id="$(jq -r '.id' <<<"$runner")"
    echo "Scale-down: membersihkan stale registration slot $slot ($name)..."
    delete_github_runner "$id" "$name" || return 1
    ((stale+=1))
  done <<<"$current_runners"

  echo "Scale-down reconcile: stopped=$stopped draining=$draining stale_removed=$stale."
}

pull_image() {
  require_root
  echo "Pulling $IMAGE_NAME ..."
  if docker pull "$IMAGE_NAME"; then
    echo "Image siap. Worker aktif tidak direstart; worker berikutnya memakai image lokal terbaru untuk tag tersebut."
    return
  fi

  local token="${GHCR_TOKEN:-$GITHUB_PAT}" user
  user="$(curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    https://api.github.com/user | jq -r '.login // empty' || true)"
  if [[ -n "$token" && -n "$user" ]] && printf '%s' "$token" | docker login ghcr.io -u "$user" --password-stdin >/dev/null 2>&1; then
    docker pull "$IMAGE_NAME"
    return
  fi
  echo "Gagal pull GHCR image. Jika private, gunakan GHCR_TOKEN PAT classic read:packages." >&2
  exit 1
}

uninstall_farm() {
  require_root
  local force=false purge_image=false arg runners busy runner id name leftovers
  shift || true
  for arg in "$@"; do
    case "$arg" in
      --force) force=true ;;
      --purge-image) purge_image=true ;;
      *) echo "Opsi tidak dikenal: $arg" >&2; exit 2 ;;
    esac
  done

  runners="$(list_farm_runners)" || {
    echo "Uninstall dibatalkan: GitHub API tidak dapat diverifikasi." >&2
    exit 1
  }
  busy="$(printf '%s\n' "$runners" | jq -r 'select(.busy == true) | "  - " + .name + " [status=" + .status + "]"' 2>/dev/null || true)"
  if [[ -n "$busy" && "$force" != "true" ]]; then
    echo "Masih ada workflow busy:" >&2
    printf '%s\n' "$busy" >&2
    echo "Gunakan --force hanya jika memang ingin memutuskannya." >&2
    exit 3
  fi

  set_cfg RUNNER_COUNT 0
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  docker ps -aq \
    --filter 'label=io.sky.github-runner-farm=true' \
    --filter "label=io.sky.github-runner-farm.instance=${INSTANCE_ID}" \
    | xargs -r docker rm -f >/dev/null 2>&1 || true

  runners="$(list_farm_runners)" || {
    echo "Supervisor berhenti tetapi GitHub API gagal; config dipertahankan untuk retry." >&2
    exit 1
  }
  while IFS= read -r runner; do
    [[ -n "$runner" ]] || continue
    id="$(jq -r '.id' <<<"$runner")"
    name="$(jq -r '.name' <<<"$runner")"
    delete_github_runner "$id" "$name"
  done <<<"$runners"

  leftovers="$(list_farm_runners)" || exit 1
  [[ -z "$leftovers" ]] || { echo "Masih ada runner yang belum terhapus; config dipertahankan." >&2; exit 1; }

  rm -f "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true

  if [[ "$purge_image" == "true" ]]; then
    docker image rm -f "$IMAGE_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$INSTALL_DIR"
  rm -f "$CTL_PATH"
  echo "Runner farm berhasil di-uninstall. Docker Engine host tetap dipertahankan."
}

usage() {
  cat <<'EOF'
Usage: runner-farmctl COMMAND [ARGS]

Commands:
  status                          Status service, desired slots, live workers, resource mode
  logs                            Follow log supervisor/worker
  scale N                         Ubah jumlah runner; scale-up aktif direconcile
  reconcile                       Sinkronkan live workers dengan RUNNER_COUNT
  limits host                     Hapus CPU/RAM limit (setiap runner dapat memakai seluruh host)
  limits CPU MEMORY [SWAP]        Set limit worker berikutnya, contoh: 2 4g 4g
  labels LABELS                   Set labels worker berikutnya
  image-pull                      Pull ulang image GHCR yang dikonfigurasi
  restart                         Restart seluruh farm; dapat memutus job aktif
  stop                            Stop seluruh farm; dapat memutus job aktif
  start                           Start farm
  config                          Tampilkan config dengan token disensor
  version                         Tampilkan versi manager dan image
  uninstall [--force] [--purge-image]
EOF
}

cmd="${1:-}"
case "$cmd" in
  status)
    service_state="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    live="$(live_slot_count)"
    if [[ -z "${RUNNER_CPU:-}" && -z "${RUNNER_MEMORY:-}" ]]; then resource_mode="host/unlimited"; else resource_mode="CPU=${RUNNER_CPU:-host} RAM=${RUNNER_MEMORY:-host} SWAP=${RUNNER_MEMORY_SWAP:-default}"; fi
    printf 'Manager version : %s\nImage           : %s\nTarget          : %s\nScope           : %s\nService         : %s\nDesired runners : %s\nLive slots      : %s\nResources       : %s\n\n' \
      "$MANAGER_VERSION" "$IMAGE_NAME" "$GITHUB_URL" "$GITHUB_SCOPE" "$service_state" "$RUNNER_COUNT" "$live" "$resource_mode"
    docker ps \
      --filter 'label=io.sky.github-runner-farm=true' \
      --filter "label=io.sky.github-runner-farm.instance=${INSTANCE_ID}" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    ;;
  logs)
    journalctl -u "$SERVICE" -f
    ;;
  scale)
    require_root
    n="${2:-}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "N harus integer > 0" >&2; exit 2; }
    (( n <= RUNNER_MAX_SLOTS )) || { echo "N melebihi RUNNER_MAX_SLOTS=$RUNNER_MAX_SLOTS" >&2; exit 2; }
    old_count="$RUNNER_COUNT"

    if (( n < old_count )); then
      runners="$(list_farm_runners)" || { echo "Scale-down dibatalkan karena status GitHub tidak dapat diverifikasi." >&2; exit 1; }
      set_cfg RUNNER_COUNT "$n"
      RUNNER_COUNT="$n"
      reconcile_scale_down "$n" "$runners"
      signal_supervisor
      echo "Desired runner count => $n. Runner busy berlebih akan drain."
    elif (( n > old_count )); then
      set_cfg RUNNER_COUNT "$n"
      RUNNER_COUNT="$n"
      signal_supervisor
      echo "Desired runner count => $n. Menunggu supervisor spawn slot baru..."
      wait_for_scale_up "$n" 30
    else
      echo "RUNNER_COUNT sudah $n; menjalankan reconciliation."
      runners="$(list_farm_runners)" || true
      [[ -z "$runners" ]] || reconcile_scale_down "$n" "$runners"
      signal_supervisor
      wait_for_scale_up "$n" 30
    fi
    ;;
  reconcile)
    require_root
    runners="$(list_farm_runners)" || { echo "Gagal membaca runner GitHub." >&2; exit 1; }
    reconcile_scale_down "$RUNNER_COUNT" "$runners"
    signal_supervisor
    wait_for_scale_up "$RUNNER_COUNT" 30
    ;;
  limits)
    require_root
    if [[ "${2:-}" == "host" || "${2:-}" == "unlimited" ]]; then
      set_cfg RUNNER_CPU ""
      set_cfg RUNNER_MEMORY ""
      set_cfg RUNNER_MEMORY_SWAP ""
      echo "CPU/RAM limit dihapus. Worker BARU dapat memakai seluruh resource host."
    else
      cpu="${2:-}"; mem="${3:-}"; swap="${4:-${3:-}}"
      [[ -n "$cpu" && -n "$mem" && -n "$swap" ]] || { usage; exit 2; }
      set_cfg RUNNER_CPU "$cpu"
      set_cfg RUNNER_MEMORY "$mem"
      set_cfg RUNNER_MEMORY_SWAP "$swap"
      echo "Worker berikutnya: CPU=$cpu RAM=$mem SWAP=$swap"
    fi
    ;;
  labels)
    require_root
    labels="${2:-}"
    [[ -n "$labels" ]] || { usage; exit 2; }
    set_cfg RUNNER_LABELS "$labels"
    echo "Labels => $labels (worker berikutnya)"
    ;;
  image-pull)
    pull_image
    ;;
  restart)
    require_root
    systemctl restart "$SERVICE"
    ;;
  stop)
    require_root
    systemctl stop "$SERVICE"
    ;;
  start)
    require_root
    systemctl start "$SERVICE"
    ;;
  config)
    sed -E 's/^(GITHUB_PAT)=.*/\1=***REDACTED***/' "$CFG"
    ;;
  version)
    printf 'runner-farmctl v%s\n%s\n' "$MANAGER_VERSION" "$IMAGE_NAME"
    ;;
  uninstall)
    uninstall_farm "$@"
    ;;
  *) usage; exit 2 ;;
esac
CTL
  chmod 0755 "$CTL_PATH"
}

write_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=GitHub Actions Ephemeral Runner Farm v${MANAGER_VERSION}
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Environment=INSTALL_DIR=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/supervisor.sh
Restart=always
RestartSec=3
TimeoutStopSec=60
KillMode=control-group
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

start_farm() {
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    die "Service runner farm gagal start."
  fi
}

print_summary() {
  local resources
  if [[ -z "$RUNNER_CPU" && -z "$RUNNER_MEMORY" ]]; then resources="host/unlimited (default)"; else resources="CPU=${RUNNER_CPU:-host}, RAM=${RUNNER_MEMORY:-host}"; fi
  cat <<EOF

============================================================
GitHub Runner Farm Manager v${MANAGER_VERSION}
============================================================
Target          : ${GITHUB_URL}
Scope           : ${GITHUB_SCOPE}
Authentication  : ${AUTH_METHOD}
Runner count    : ${RUNNER_COUNT}
Max slots       : ${RUNNER_MAX_SLOTS}
Resources       : ${resources}
Image           : ${IMAGE_NAME}
Config          : ${INSTALL_DIR}/config.env
Control         : runner-farmctl

Commands:
  runner-farmctl status
  runner-farmctl logs
  runner-farmctl scale 8
  runner-farmctl reconcile
  runner-farmctl limits host
  runner-farmctl limits 2 4g 4g
  runner-farmctl labels "universal,docker,java,node,android"
  runner-farmctl image-pull
  runner-farmctl version

Workflow:
  runs-on: [self-hosted, universal]
============================================================
EOF
}

installer_usage() {
  cat <<EOF
GitHub Runner Farm Manager v${MANAGER_VERSION}

Usage:
  sudo ./install.sh
  sudo ./install.sh install
  sudo ./install.sh update-control
  sudo ./install.sh uninstall [--force] [--purge-image]
  ./install.sh version

Environment for non-interactive install:
  GITHUB_URL=https://github.com/OWNER/REPO
  GITHUB_PAT=...
  RUNNER_COUNT=4
  IMAGE_NAME=${IMAGE_NAME}
EOF
}

main() {
  local action="${1:-install}"
  case "$action" in
    version|--version|-v)
      printf 'GitHub Runner Farm Manager v%s\nImage: %s\n' "$MANAGER_VERSION" "$IMAGE_NAME"
      return
      ;;
  esac

  require_root
  case "$action" in
    install)
      shift || true
      [[ $# -eq 0 ]] || die "Argumen install tidak dikenal: $*"
      check_host
      install_host_dependencies
      install_docker_host
      collect_config
      check_github_auth
      pull_worker_image
      write_config
      write_supervisor
      write_control_tool
      write_systemd_service
      start_farm
      print_summary
      ;;
    update-control)
      shift
      [[ $# -eq 0 ]] || die "update-control tidak menerima argumen."
      [[ -f "$INSTALL_DIR/config.env" ]] || die "Runner farm tidak ditemukan."
      write_control_tool
      log "runner-farmctl diperbarui ke v${MANAGER_VERSION}; runner aktif tidak direstart."
      ;;
    uninstall)
      shift
      [[ -f "$INSTALL_DIR/config.env" ]] || die "Runner farm tidak ditemukan."
      write_control_tool
      exec "$CTL_PATH" uninstall "$@"
      ;;
    help|-h|--help)
      installer_usage
      ;;
    *)
      installer_usage
      die "Command tidak dikenal: $action"
      ;;
  esac
}

main "$@"
