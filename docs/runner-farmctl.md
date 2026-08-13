# `runner-farmctl` Command Reference

Version: **v1.0.0**

## `status`

```bash
sudo runner-farmctl status
```

Menampilkan versi manager, image, target, scope, status systemd, desired runner count, live slots, resource mode, dan container aktif.

## `logs`

```bash
sudo runner-farmctl logs
```

Mengikuti log service secara realtime melalui `journalctl -f`.

## `scale N`

```bash
sudo runner-farmctl scale 8
sudo runner-farmctl scale 2
```

Mengubah desired runner count secara live.

Scale-up:

- config diperbarui;
- supervisor dibangunkan dengan `USR1`;
- slot yang belum ada dibuat;
- command memverifikasi live slots mencapai target.

Scale-down:

- runner idle di atas target dihentikan/deregister;
- runner busy di atas target melakukan drain dan tidak respawn setelah job selesai.

## `reconcile`

```bash
sudo runner-farmctl reconcile
```

Memaksa live workers kembali sesuai `RUNNER_COUNT`. Berguna setelah gangguan Docker/systemd/API atau bila jumlah live worker berbeda dengan desired state.

## `limits host`

```bash
sudo runner-farmctl limits host
```

Menghapus CPU/RAM/swap limit Docker untuk worker berikutnya. Ini adalah default v1.0.0.

Setiap worker dapat memakai resource host yang tersedia; resource tidak direservasi eksklusif per runner.

## `limits CPU MEMORY [SWAP]`

```bash
sudo runner-farmctl limits 2 4g 4g
```

Mengatur limit worker berikutnya:

- CPU: `2`
- RAM: `4g`
- memory+swap limit: `4g`

Perubahan tidak memutus runner aktif.

## `labels LABELS`

```bash
sudo runner-farmctl labels "universal,docker,java,node,android"
```

Mengubah custom labels untuk ephemeral worker berikutnya.

## `image-pull`

```bash
sudo runner-farmctl image-pull
```

Menjalankan `docker pull` terhadap `IMAGE_NAME` yang dikonfigurasi. Worker aktif tidak direstart.

## `restart`

```bash
sudo runner-farmctl restart
```

Restart seluruh systemd service dan worker. **Dapat memutus workflow aktif.**

## `stop`

```bash
sudo runner-farmctl stop
```

Menghentikan farm. **Dapat memutus workflow aktif.**

## `start`

```bash
sudo runner-farmctl start
```

Menyalakan service dan membuat desired runner slots.

## `config`

```bash
sudo runner-farmctl config
```

Menampilkan `config.env` dengan `GITHUB_PAT` disensor.

## `version`

```bash
runner-farmctl version
```

Menampilkan manager version dan configured GHCR image.

## `uninstall`

```bash
sudo runner-farmctl uninstall
```

Deregister runner farm dari GitHub, stop systemd service, hapus container dan instalasi lokal. Docker Engine host tidak dihapus.

### `--purge-image`

```bash
sudo runner-farmctl uninstall --purge-image
```

Selain uninstall normal, hapus configured worker image dari Docker host.

### `--force`

```bash
sudo runner-farmctl uninstall --force
```

Mengizinkan uninstall walaupun terdapat runner busy. Workflow yang sedang berjalan dapat terputus.

## File penting

```text
/opt/github-runner-farm/config.env
/opt/github-runner-farm/supervisor.sh
/usr/local/bin/runner-farmctl
/etc/systemd/system/github-runner-farm.service
```
