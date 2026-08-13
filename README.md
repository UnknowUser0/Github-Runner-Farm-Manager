# GitHub Runner Farm Manager

GitHub Runner Farm Manager membuat sekumpulan **ephemeral self-hosted GitHub Actions runners** di satu mesin Ubuntu. Setiap runner berjalan di container disposable sendiri, memiliki Docker daemon sendiri, filesystem/workspace/cache sendiri, dan hanya menerima satu job sebelum dihancurkan.

**Current version:** `v1.0.0`

**Universal worker image:** `ghcr.io/skyteamexec/github-runner-farm-manager:v1.0.0`

## Fitur v1.0.0

- Auto-detect target GitHub repository atau organization dari URL.
- Login menggunakan browser/device flow melalui `gh auth login --web`, atau PAT.
- Default 4 runner, dapat di-scale live hingga `RUNNER_MAX_SLOTS`.
- Scale-up aktif direconcile dan diverifikasi; tidak perlu restart service.
- Scale-down menghentikan runner idle berlebih dan membiarkan runner busy menyelesaikan job.
- CPU/RAM default **tanpa limit Docker**: setiap runner dapat memakai resource host penuh.
- Optional per-runner CPU/RAM limits.
- Runner ephemeral: satu job lalu container dibuang dan dibuat baru.
- Docker-in-Docker per runner; tidak membagikan `/var/run/docker.sock` host.
- Worker image dibangun di GitHub Actions dan dipublish ke GHCR; installer tidak membangun image lokal.
- Image dan manager memiliki versi SemVer.
- Fokus v1: Ubuntu Linux `amd64`.

## Instalasi

```bash
curl -fsSL \
  https://raw.githubusercontent.com/SkyTeamExec/Github-Runner-Farm-Manager/main/install.sh \
  -o install.sh

chmod +x install.sh
sudo ./install.sh
```

Installer akan meminta:

1. GitHub URL repository/organization.
2. Authentication method: `web` atau `pat`.

Contoh target repository:

```text
https://github.com/OWNER/REPOSITORY
```

Contoh organization:

```text
https://github.com/ORGANIZATION
```

atau:

```text
https://github.com/organizations/ORGANIZATION
```

Scope `repo`/`org` tidak perlu dipilih manual.

## Login browser/device

Default authentication adalah:

```text
web
```

Installer memasang GitHub CLI bila belum tersedia dan menjalankan web/device authentication. Pada server headless, GitHub CLI akan menampilkan URL/kode autentikasi yang dapat dibuka dari browser perangkat lain.

PAT masih tersedia dengan memilih:

```text
pat
```

Untuk mode non-interaktif:

```bash
sudo env \
  GITHUB_URL=https://github.com/OWNER/REPOSITORY \
  GITHUB_PAT=YOUR_TOKEN \
  RUNNER_COUNT=4 \
  ./install.sh
```

## Resource default

v1.0.0 **tidak memberikan `--cpus`, `--memory`, atau `--memory-swap` ke worker secara default**.

Jadi pada mesin 16 CPU / 64 GB RAM, masing-masing runner secara teknis dapat menggunakan sampai resource yang tersedia pada host. Ini bukan reservation 16 CPU + 64 GB per runner; semua runner tetap bersaing menggunakan scheduler/kernel host yang sama.

Cek:

```bash
sudo runner-farmctl status
```

Output resource default:

```text
Resources       : host/unlimited
```

Untuk memasang limit:

```bash
sudo runner-farmctl limits 2 4g 4g
```

Kembali ke host/unlimited:

```bash
sudo runner-farmctl limits host
```

Limit baru berlaku pada worker ephemeral berikutnya dan tidak memutus worker yang sedang menjalankan job.

## Scaling

Scale ke 8:

```bash
sudo runner-farmctl scale 8
```

Scale ke 2:

```bash
sudo runner-farmctl scale 2
```

### Scale-up

Supervisor membaca desired state dan membuat slot yang belum ada. `runner-farmctl scale` kemudian menunggu dan memverifikasi live slot agar kegagalan spawn tidak diam-diam dianggap sukses.

### Scale-down

- Runner berlebih yang idle: dihentikan dan deregister segera.
- Runner berlebih yang busy: dibiarkan menyelesaikan workflow lalu tidak respawn.

Paksa sinkronisasi:

```bash
sudo runner-farmctl reconcile
```

## Image GHCR

Image universal dibangun dari:

```text
docker/Dockerfile
```

Workflow:

```text
.github/workflows/build-runner-image.yml
```

Tags v1.0.0:

```text
ghcr.io/skyteamexec/github-runner-farm-manager:v1.0.0
ghcr.io/skyteamexec/github-runner-farm-manager:v1
ghcr.io/skyteamexec/github-runner-farm-manager:latest
ghcr.io/skyteamexec/github-runner-farm-manager:sha-...
```

Installer v1.0.0 menggunakan tag versioned `v1.0.0`, bukan `latest`.

Pull ulang image:

```bash
sudo runner-farmctl image-pull
```

## Toolchain universal Ubuntu

Image v1 menyertakan toolchain umum CI/CD dalam satu image:

- Docker Engine, Compose v2, Buildx
- Git, Git LFS, GitHub CLI
- Java 17 dan Java 21
- Maven dan Gradle
- Node.js 24 LTS, npm, pnpm, Yarn/Corepack
- Bun dan Deno
- Python 3, pip, pipx
- Go stable
- Rust stable, Cargo, rustfmt, Clippy
- .NET 10 LTS
- PHP dan Composer
- Ruby dan Bundler
- GCC/G++, Clang/LLVM, CMake, Ninja, Meson
- Android command-line SDK, platform-tools/ADB, API 36, Build Tools 36.0.0
- PostgreSQL, MySQL, Redis clients
- kubectl, Helm, Terraform, AWS CLI v2, yq
- Google Chrome stable
- ffmpeg, ImageMagick, protobuf compiler, ShellCheck dan utility Linux umum

GitHub Actions runner binary terbaru dibake saat image dibangun. Installer juga mengambil URL binary yang tersedia untuk target repository/organization; jika GitHub progressive rollout memberikan versi berbeda, entrypoint worker mengambil versi target tersebut saat container dimulai.

## Workflow

```yaml
jobs:
  build:
    runs-on: [self-hosted, universal]

    steps:
      - uses: actions/checkout@v7.0.1
      - run: node --version
      - run: java -version
      - run: docker version
```

Labels default:

```text
universal,docker,java,node,python,go,rust,dotnet,android,ubuntu
```

## Uninstall

Normal:

```bash
sudo runner-farmctl uninstall
```

Hapus image juga:

```bash
sudo runner-farmctl uninstall --purge-image
```

Memutus job busy secara paksa:

```bash
sudo runner-farmctl uninstall --force
```

`--force` sebaiknya hanya digunakan ketika workflow aktif memang boleh dihentikan.

## Dokumentasi command

Lihat [`docs/runner-farmctl.md`](docs/runner-farmctl.md).

## Security model

Worker menggunakan privileged Docker-in-Docker untuk kompatibilitas Docker/Compose yang luas. Ini memberikan pemisahan workspace/cache/Docker daemon antar-runner, tetapi privileged container **bukan security boundary setara VM** terhadap workflow hostile. Jangan menjalankan arbitrary untrusted public-PR workloads tanpa boundary tambahan seperti VM/microVM per job.
