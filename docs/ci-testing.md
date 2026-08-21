# Virtual testing environment

`rpi-setup` ships with a GitHub Actions workflow
([`.github/workflows/test-provision.yml`](../.github/workflows/test-provision.yml))
that exercises the tasks against a real **Raspberry Pi OS arm64** disk image
instead of trusting shellcheck alone. This document explains how it works, what
it covers, its known limitations, and how to maintain it.

## Why two provision jobs

Running the tasks on a plain x86 Linux machine hides most of the problems that
only appear on Raspberry Pi OS (systemd units, arm64 Docker images, Debian/apt
quirks). The workflow uses two increasingly faithful layers:

| Job                  | Trigger            | Mechanism                              | Fidelity | Speed    |
|----------------------|--------------------|----------------------------------------|----------|----------|
| `provision-gate`     | every `pull_request` | booted `systemd-nspawn` container      | high     | minutes  |
| `provision-qemu`     | `workflow_dispatch` (manual) | full QEMU VM, Pi 3B+ emulation | highest  | slow     |
| `syntax`             | PR, push to `main`, manual | `bash -n`, shellcheck, `--list` | -        | seconds  |
| `flash-e2e`          | PR, manual        | `host/flash.ps1` run on a Windows VM against a virtual SD card | high     | minutes  |

`flash-e2e` is part of the separate
[`.github/workflows/test-flash.yml`](../.github/workflows/test-flash.yml) workflow
and validates the Windows host flasher - see
[Flash script testing](#flash-script-testing).

- **`provision-gate`** is the per-PR gate. It boots the image with systemd as
  PID 1 (`ethanjli/pinspawn-action` with `boot: true`) inside a
  `systemd-nspawn` container on an `ubuntu-latest` runner. Systemd PID 1 is
  essential: several tasks rely on `systemctl` (`docker`, `web`,
  `monitoring`, `samba`, `netalertx`, `teamspeak`), which fails in a plain
  chroot-style container that never boots an init program.
- **`provision-qemu`** is the manual maximum-fidelity run. It boots the same
  image in `qemu-system-aarch64` emulating a Raspberry Pi 3B+
  (`ethanjli/piqemu-action`, `machine: rpi-3b+`). Use it before a release or
  whenever a task change touches hardware-dependent behavior.

The `syntax` job is a fast pre-check; both provision jobs `needs: syntax` so
lint failures stop before the expensive emulation starts.

## What runs

Both provision jobs run the same provisioning + verification sequence on the
pinned image, as `root`:

```
base docker samba web monitoring pihole netalertx teamspeak
```

(`tailscale` is deliberately excluded - see [Interactive tasks](#interactive-tasks).)

After provisioning, the job verifies:

1. `systemctl is-active` for `docker`, `smbd`, `nginx`, `netdata`, `fail2ban`.
2. `docker ps` (the `netalertx` and `teamspeak` containers must be running).
3. `curl http://localhost:19999` (Netdata) and `http://localhost:20211`
   (NetAlertX), with a retry loop because those take a while to listen.
4. An **idempotency re-run** of the same `setup.sh` invocation - every task must
   exit 0 on a second pass (this is what the README promises: "re-running is
   safe").

Any failing check makes the whole run fail, so a red `provision-gate` is a
regression to fix, not a flake to retry.

### Interactive tasks

| Task        | CI handling                                                                 |
|-------------|-----------------------------------------------------------------------------|
| `samba`     | Non-interactive via the `SAMBA_PASSWORD` env override (`SAMBA_PASSWORD=testpw`); stdin is not used because the long `apt-get install samba` in the task consumes a piped stdin before the prompt runs. |
| `pihole`    | `PIHOLE_CONFIRM=yes` skips the interactive confirmation; the installer then runs with defaults. |
| `tailscale` | **Excluded** - `tailscale up` blocks waiting for interactive login.         |

Because the container/VM runs as `root`, `real_user()` resolves to `root`, so
`samba` configures `/home/root/nas-share` and warns. That is expected and
acceptable for CI.

## The pinned image

Both jobs use the same pinned Raspberry Pi OS Lite (64-bit) image so the two
layers agree with each other and with the README's "Bookworm or later" promise:

```
2025-05-13-raspios-bookworm-arm64-lite.img.xz
sha256 62d025b9bc7ca0e1facfec74ae56ac13978b6745c58177f081d39fbb8041ed45
```

It is pinned to **Bookworm**, not the latest release, because `piqemu-action`
builds a Bookworm-specific patched DTB (it merges the `disable-bt` overlay to
make the emulated Pi boot); newer images (e.g. Trixie) are not yet compatible.
The version, URL and SHA-256 live in the `env:` block at the top of the
workflow.

### Bumping the image

1. Pick a new image and note its `.sha256` from the
   [download index](https://downloads.raspberrypi.com/raspios_lite_arm64/images/).
   Example (latest at the time of writing):
   `2026-06-18-raspios-trixie-arm64-lite.img.xz`,
   sha256 `acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3`.
2. Update `RPI_IMAGE_VERSION`, `RPI_IMAGE_URL` and `RPI_IMAGE_SHA256` in
   `.github/workflows/test-provision.yml`.
3. Change the cache key (`raspios-bookworm-arm64-${{ env.RPI_IMAGE_VERSION }}`)
   so a fresh image is downloaded.
4. If moving off Bookworm, first confirm `piqemu-action` supports the new
   image (its DTB build script is Bookworm-specific) and that the image's
   partition layout/boot behavior still matches nspawn/QEMU.
5. Run the manual `provision-qemu` job before merging the bump.

## How the image is prepared

Shared steps in both provision jobs:

1. **Download** the `.img.xz` (cached by `actions/cache`, keyed on the image
   version) and **verify** the SHA-256.
2. **Extract** to a raw `.img`.
3. **Grow** the root partition to 8G (`truncate` + `parted resizepart` +
   `resize2fs` on a loop device). The stock image has only ~1-2 GB free, which
   is too small for `apt upgrade` plus the `netalertx`/`teamspeak` images.

The two layers then differ in how they get the repo into the OS:

- **gate**: `--bind ${{ github.workspace }}:/workspace` is passed to
  `systemd-nspawn`; the run script does `cd /workspace`.
- **qemu**: QEMU has no bind mounts, so a prep step mounts the image's root
  partition, copies the checkout into `/opt/rpi-setup`, and unmounts; the run
  script does `cd /opt/rpi-setup`.

## Flash script testing

`host/flash.ps1` (the Windows host flasher) is covered by
[`.github/workflows/test-flash.yml`](../.github/workflows/test-flash.yml), which
runs two jobs:

| Job        | What it does                                                        |
|------------|---------------------------------------------------------------------|
| `flash`    | Static: parses `host/flash.ps1` for syntax errors and runs the pure-logic unit tests in `ci/test-flash.ps1` (version parsing, install-path detection, disk-filtering logic). |
| `flash-e2e`| Runs the real `host/flash.ps1` setup flow end-to-end on a GitHub-hosted Windows VM, against a **virtual SD card** instead of a physical one. |

The `flash` and `flash-e2e` jobs run **in parallel** (no `needs:` between them) to reduce total PR latency.

The `flash-e2e` job is the part that "runs the setup in a virtual environment":

1. The runner VM (already isolated and ephemeral) creates a dynamic 12 GB VHDX
   and attaches it with `Mount-VHD`, so it appears as a normal disk.
2. `host/flash.ps1` is invoked with `-AllowVirtualDisk -Disk <n>` (the switch
   exists so a non-removable, non-system disk can be flashed by explicit number;
   interactive users still only see removable SD/USB disks). The script then
   runs its real flow: download + SHA-256-verify the latest Raspberry Pi OS
   image, silently install Raspberry Pi Imager, flash the image to the virtual
   disk, and write the `ssh` / `userconf.txt` first-boot files. The image and
   Imager installers are cached (date-keyed with a `restore-keys: flash-downloads-` fallback) so PRs do not re-download.
3. The job then re-attaches and checks that the boot partition really contains
   `ssh` and `userconf.txt` - the same result a user gets on a physical card.

This exercises the Windows flashing flow (download, checksum, Imager install
and CLI write, boot-partition setup) that `provision-gate`/`provision-qemu`
cannot, because those only cover the on-Pi provisioning side. `flash-e2e` gates
PRs and manual runs (it skips plain `push` to `main`, which the PR gate already
covers). It needs admin - GitHub-hosted Windows VMs run elevated with UAC
disabled, which is also required to attach the VHDX and to run Imager's silent
installer.

**Timeout guard:** `Install-Imager` and `Uninstall-Imager` now use a watched
process with a 5 min / 3 min hard timeout and 15 s heartbeats. If the
`pnputil` driver step inside the Imager installer hangs (a known issue on
headless CI runners), the script kills the process tree and fails fast with the
installer log tail instead of burning the full 60 min job timeout.

**CI avoids the installer entirely:** The `flash-e2e` job downloads
`innoextract`, unpacks the Imager installer (which does **not** execute the
`[Run]` section where `pnputil` lives), and passes the extracted
`rpi-imager.exe` to `flash.ps1` via `-ImagerExe`. This completely sidesteps the
driver-install hang while using the exact same Imager binary.

**Verbosity:** Every progress line from `flash.ps1` is now prefixed with an
elapsed `[hh:mm:ss]` timestamp, and the workflow emits `::group::` folds with
disk state dumps before/after the flash step.

## Known limitations

- **Not a real Pi in the gate.** `is_pi()` is false inside the nspawn
  container, so `setup.sh` prints "This does not appear to be a Raspberry Pi"
  and hardware-only behavior (EEPROM update, `raspi-config`) is skipped by the
  tasks themselves. The QEMU job also lacks real Pi hardware, but is closer.
- **Emulation is slow.** The gate emulates arm64 via QEMU user-mode binaries on
  an x86 runner; Docker image pulls and container startup can take many
  minutes. The QEMU job is full-TCG emulation and slower still - hence it is
  manual with generous timeouts.
- **`piqemu-action` can hang/freeze.** The action author documents that RPi
  QEMU VMs occasionally freeze mid-run; a rerun of the manual job is the
  workaround. This is why the gate uses nspawn, not QEMU.
- **RPi 3B+ only.** `piqemu-action` only supports the `rpi-3b+` machine type
  (QEMU's `raspi4b` has no working networking yet).
- **arm64 hosted runners are avoided.** GitHub's hosted arm64 runners have a
  spontaneous-shutdown bug with *booted* nspawn containers, so the workflow
  deliberately runs both provision jobs on `ubuntu-latest` (x86_64).
- **`pihole` installer is headless.** With `PIHOLE_CONFIRM=yes` and no TTY the
  official installer proceeds with defaults; if a future installer version
  starts requiring dialogs, `pihole` may need to be excluded like `tailscale`.
- **Docker-in-nspawn needs capabilities.** The gate passes
  `--capability=CAP_NET_ADMIN` so Docker can set up its bridge/iptables inside
  the container.

## Local reproduction

If you can run `systemd-nspawn` locally on a Linux host, you can approximate
the gate by hand:

```bash
sudo systemd-nspawn --directory=/mnt/raspi-root --boot --bind "$PWD:/workspace"
# inside the container:
cd /workspace && PIHOLE_CONFIRM=yes SAMBA_PASSWORD=testpw bash setup.sh base docker samba web monitoring pihole netalertx teamspeak
```

The GitHub Actions workflow is the supported path though; the actions install
`systemd-container`, `qemu-user-static`, `binfmt-support` (and
`qemu-system-aarch64` for QEMU) automatically.

## Adding or changing tasks

- If a task gains a new interactive prompt, feed it via the piped stdin or
  an env var in the `run:` blocks, or exclude it from CI (with a documented
  reason) like `tailscale`.
- If a task's verification needs a new service or port, extend the
  "Verifying services" / "Verifying web endpoints" sections in **both** jobs.
- Keep the two jobs' `run:` blocks identical apart from the `cd` target, so the
  gate and the QEMU job never drift apart.