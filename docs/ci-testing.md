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
| `samba`     | Password piped via stdin (`printf 'testpw\ntestpw\n'`).                     |
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
cd /workspace && PIHOLE_CONFIRM=yes bash setup.sh base docker samba web monitoring pihole netalertx teamspeak
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