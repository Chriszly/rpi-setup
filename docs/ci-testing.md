# Virtual testing environment

`rpi-setup` ships with a GitHub Actions workflow
([`.github/workflows/test-provision.yml`](../.github/workflows/test-provision.yml))
that exercises the tasks against a real **Raspberry Pi OS arm64** disk image
instead of trusting shellcheck alone. This document explains how it works, what
it covers, its known limitations, and how to maintain it.

## Jobs at a glance

Running the tasks on a plain x86 Linux machine hides most of the problems that
only appear on Raspberry Pi OS (systemd units, arm64 Docker images, Debian/apt
quirks). The workflow uses several increasingly faithful layers:

| Job              | Trigger                      | Mechanism                                        | Fidelity | Speed   |
|------------------|------------------------------|--------------------------------------------------|----------|---------|
| `syntax`         | PR, push to `main`, manual   | `bash -n`, shellcheck, actionlint, `--list`      | -        | seconds |
| `unit`           | PR, push to `main`, manual   | `ci/test-lib.sh`, `ci/test-setup.sh`             | -        | seconds |
| `docker-smoke`   | PR, push to `main`, manual   | Docker tasks on a plain `ubuntu-latest` runner   | low      | minutes |
| `provision-gate` | `pull_request` touching provisioning | booted `systemd-nspawn` container, latest release and Bookworm, two parallel halves each | high | minutes |
| `provision-qemu` | `workflow_dispatch` (manual) | full QEMU VM, Pi 3B+ emulation                   | highest  | slow    |

- **`syntax`** and **`unit`** are fast pre-checks; the three provisioning jobs
  `needs:` both, so lint or unit-test failures stop before the expensive part.
  `unit` runs the tests under `sudo` so the root-only assertions (UID
  assignment, the `setup.sh` menu) are included.
- **`docker-smoke`** runs the `docker`, `netalertx` and `teamspeak` tasks on the
  stock Ubuntu runner (x86_64, Docker preinstalled). It is not a Pi, but it is
  the only per-PR coverage of the compose/UID logic, because Docker does not
  work inside the nspawn gate (see below).
- **`provision-gate`** is the per-PR gate. It boots the image with systemd as
  PID 1 (`ethanjli/pinspawn-action` with `boot: true`) inside a
  `systemd-nspawn` container on an `ubuntu-latest` runner. Systemd PID 1 is
  essential: several tasks rely on `systemctl` (`web`, `monitoring`, `samba`),
  which fails in a plain chroot-style container that never boots an init program.
  Each release runs as two parallel jobs, `system` (`base samba`) and `web`
  (`web monitoring pihole`): package installs under arm64 emulation dominate
  the gate, so splitting them roughly halves its wall time. A small `changes`
  job skips the gate for PRs that touch none of `setup.sh`, `lib/`, `tasks/`,
  `ci/provision.sh`, this workflow or `.github/actions/` (a skipped job counts
  as passed for required checks).
- **`provision-qemu`** is the manual maximum-fidelity run. It boots the same
  image in `qemu-system-aarch64` emulating a Raspberry Pi 3B+
  (`ethanjli/piqemu-action`, `machine: rpi-3b+`). Use it before a release or
  whenever a task change touches hardware-dependent behavior. It is the only
  job that runs the Docker tasks on arm64.

Changes that touch only Markdown, `docs/` or `LICENSE` skip this workflow
(`paths-ignore`); they cannot change what provisioning does.

The two flash-script workflows are separate:
[`test-flash.yml`](../.github/workflows/test-flash.yml) parses and lints
`host/flash.ps1` with PSScriptAnalyzer (rule exclusions live in
[`PSScriptAnalyzerSettings.psd1`](../PSScriptAnalyzerSettings.psd1)) and runs
`ci/test-flash.ps1`, and only runs when one of those files (or the workflow
itself) changes; `pr-template-validation.yml` checks the PR description.

## What runs

All three provisioning jobs run [`ci/provision.sh`](../ci/provision.sh), which
is the single source of truth for the task list and the checks. It selects a
**profile**, either from `PROVISION_PROFILE` or by auto-detecting a container:

| Profile     | Used by          | Tasks                                                              | Verified                                                         |
|-------------|------------------|--------------------------------------------------------------------|------------------------------------------------------------------|
| `container` | auto-detected in any container | `base samba web monitoring pihole`                   | `smbd nginx netdata fail2ban` active, `ssh` enabled; Netdata :19999 and nginx :80 |
| `container-system` | `provision-gate` (`system`) | `base samba`                                           | `smbd fail2ban` active, `ssh` enabled                            |
| `container-web` | `provision-gate` (`web`) | `web monitoring pihole`                                       | `nginx netdata` active; Netdata :19999 and nginx :80             |
| `full`      | `provision-qemu` | `base docker samba web monitoring pihole netalertx teamspeak`      | above plus `docker` active, both containers running, :20211      |
| `docker`    | `docker-smoke`   | `docker netalertx teamspeak`                                       | `docker` active, both containers running, NetAlertX on :20211    |

(`tailscale` is deliberately excluded everywhere - see
[Interactive tasks](#interactive-tasks).)

After provisioning, every profile does:

1. `systemctl is-active` for each service in the profile.
2. `docker ps` and a running-state check for each expected container.
3. `curl` against each web endpoint with a retry loop (Netdata and NetAlertX
   take a while to listen). Endpoints are requested on the machine's LAN
   address (`hostname -I`), not `localhost`, so a service that only listens on
   loopback fails here the way it would for a user on another PC.
4. A **settings check**: the run takes its settings from a central
   `rpi-setup.env` (in a temp folder, via `RPI_SETUP_CONFIG_DIR`), exactly as a
   user would, and verifies that `WEB_TITLE`, `BASE_TIMEZONE` and
   `BASE_JOURNAL_MAX_SIZE` reached the Pi and that a Samba user exists.
5. An **idempotency re-run** of the same `setup.sh` invocation - every task must
   exit 0 on a second pass (this is what the README promises: "re-running is
   safe"). The re-run's settings file has no `SAMBA_PASSWORD` and there is no
   terminal, so `samba` must keep the existing password rather than prompt or
   generate one. Services, endpoints and settings are verified again afterwards.

Any failing check makes the whole run fail, so a red job is a regression to
fix, not a flake to retry.

### Failure logs

When any step of `ci/provision.sh` fails, an `EXIT` trap writes the guest's
`journalctl -b`, `dmesg`, `/var/log/*.log`, `systemctl status` for every
expected service and `docker logs` for every expected container into
`<workdir>/ci-logs/`. The workflow uploads that directory as an artifact
(`provision-gate-logs`, `provision-qemu-logs` or `docker-smoke-logs`):

- **gate / smoke**: the workdir is the checkout, so the logs land directly on
  the runner.
- **qemu**: there is no bind mount, so a follow-up step mounts the image after
  the VM shuts down and copies `/opt/rpi-setup/ci-logs` out.

### Interactive tasks

| Task        | CI handling                                                                 |
|-------------|-----------------------------------------------------------------------------|
| `samba`     | `SAMBA_PASSWORD=testpw` in the settings file on the first run; without it the task would generate a password, never prompt. |
| `pihole`    | Skips itself inside a container (Pi-hole needs port 53), so its unattended install is only exercised on a real Pi. |
| `tailscale` | **Excluded** - `tailscale up` blocks waiting for interactive login.         |

Because the container/VM runs as `root`, `real_user()` resolves to `root`, so
`samba` configures `/home/root/nas-share` and warns. That is expected and
acceptable for CI.

## The images

The gate runs as a matrix over two Raspberry Pi OS Lite (64-bit) images,
matching the README's "Trixie or Bookworm" promise:

- **`latest`**: resolved at run time from the
  [download index](https://downloads.raspberrypi.com/raspios_lite_arm64/images/),
  exactly as `host/flash.sh` does, and verified against that release's own
  `.sha256`. This is the image a user flashes today (currently Trixie), so a
  new Raspberry Pi OS release that breaks a task shows up on the next PR.
- **`bookworm`**: pinned, for Pis that are still on Bookworm:

  ```
  2025-05-13-raspios-bookworm-arm64-lite.img.xz
  sha256 62d025b9bc7ca0e1facfec74ae56ac13978b6745c58177f081d39fbb8041ed45
  ```

`provision-qemu` uses the pinned Bookworm image only, because `piqemu-action`
builds a Bookworm-specific patched DTB (it merges the `disable-bt` overlay to
make the emulated Pi boot); Trixie images are not yet compatible with it. The
gate's images live in the `provision-gate` job's `matrix.include`; the QEMU
image in the `env:` block at the top of the workflow. Both go through the
shared [`prepare-image`](../.github/actions/prepare-image/action.yml)
composite action, which accepts `version: latest` or a pinned
`version`/`url`/`sha256`.

### Bumping the pinned image

1. Pick a new image and note its `.sha256` from the
   [download index](https://downloads.raspberrypi.com/raspios_lite_arm64/images/).
2. Update the `bookworm` entry of the `provision-gate` matrix and
   `RPI_IMAGE_VERSION`, `RPI_IMAGE_URL`, `RPI_IMAGE_SHA256` in
   `.github/workflows/test-provision.yml`. The cache key is derived from the
   version, so a fresh image is downloaded automatically.
3. If moving off Bookworm, first confirm `piqemu-action` supports the new
   image (its DTB build script is Bookworm-specific) and that the image's
   partition layout/boot behavior still matches nspawn/QEMU.
4. Run the manual `provision-qemu` job before merging the bump.

## How the image is prepared

The `prepare-image` composite action does the same thing for both jobs:

1. **Restore** the `.img.xz` from `actions/cache` (keyed on the image version)
   or **download** it, then **verify** the SHA-256.
2. **Save** it to the cache right away, so a later provisioning failure does
   not force a re-download on the next run.
3. **Extract** to a raw `.img`.
4. **Grow** the root partition to 8G (`truncate` + `parted resizepart` +
   `resize2fs` on a loop device). The stock image has only ~1-2 GB free, which
   is too small for `apt upgrade` plus the `netalertx`/`teamspeak` images.

Before booting, the gate installs the host packages `pinspawn-action` needs
(`systemd-container`, `qemu-user-static`, `binfmt-support`) through the
[`nspawn-deps`](../.github/actions/nspawn-deps/action.yml) action, which caches
their `.deb` files keyed on the runner image. The runner's Ubuntu mirror serves
them at under 120 kB/s, so letting `pinspawn-action` download them cost 2-4
minutes per run.

The two layers then differ in how they get the repo into the OS:

- **gate**: `--bind ${{ github.workspace }}:/workspace` is passed to
  `systemd-nspawn`; the run script does `cd /workspace`.
- **qemu**: QEMU has no bind mounts, so a prep step mounts the image's root
  partition, copies the checkout into `/opt/rpi-setup`, and unmounts; the run
  script does `cd /opt/rpi-setup`.

## Known limitations

- **No first-boot test.** The gate only checks that the image still enables
  `userconfig.service` and `sshswitch.service`, the services that read the
  `userconf.txt` and `ssh` files `host/flash.sh` and `host/flash.ps1` write
  (true for Bookworm and for Trixie, which also ships cloud-init). The first
  boot itself is only tested on real hardware.
- **Not a real Pi in the gate.** `is_pi()` is false inside the nspawn
  container, so `setup.sh` prints "This does not appear to be a Raspberry Pi"
  and hardware-only behavior (EEPROM update, `raspi-config`) is skipped by the
  tasks themselves. The QEMU job also lacks real Pi hardware, but is closer.
- **No systemd sandboxing in the gate.** Units that use mount-namespace
  sandboxing (`ProtectSystem=`, `PrivateTmp=`, `LogNamespace=` ...) fail with
  "Failed at step NAMESPACE" in the nspawn container; `systemd-logind` does
  too. `ci/provision.sh` replaces the `netdata` unit (whose upstream package, used
  on Trixie, is sandboxed) with a copy minus those lines, inside containers
  only.
- **No Docker in the gate.** Docker cannot run inside the nspawn container, so
  the `container` profile skips `docker`, `netalertx` and `teamspeak`. Those
  tasks get x86 coverage from `docker-smoke` and arm64 coverage only from the
  manual QEMU job.
- **Emulation is slow.** The gate emulates arm64 via QEMU user-mode binaries on
  an x86 runner; apt operations take many minutes. The QEMU job is full-TCG
  emulation and slower still - hence it is manual with generous timeouts.
- **`piqemu-action` can hang/freeze.** The action author documents that RPi
  QEMU VMs occasionally freeze mid-run; a rerun of the manual job is the
  workaround. This is why the gate uses nspawn, not QEMU.
- **RPi 3B+ only.** `piqemu-action` only supports the `rpi-3b+` machine type
  (QEMU's `raspi4b` has no working networking yet).
- **arm64 hosted runners are avoided.** GitHub's hosted arm64 runners have a
  spontaneous-shutdown bug with *booted* nspawn containers, so the workflow
  deliberately runs both provision jobs on `ubuntu-latest` (x86_64). Re-checked on
  `ubuntu-24.04-arm` on 2026-09-30: the image boots in about a second, then
  systemd shuts the container down right after the login prompt.
- **`pihole` is skipped in containers.** Its unattended install (pre-seeded
  `/etc/pihole/pihole.toml`, `--unattended`) needs a real Pi or the QEMU job.

## Local reproduction

The unit tests and linters run anywhere with bash:

```bash
bash ci/test-lib.sh          # sudo for the UID-assignment tests
bash ci/test-setup.sh        # sudo for the menu/CLI tests
shellcheck setup.sh lib/*.sh tasks/*.sh host/*.sh ci/*.sh config/*.sh
docker run --rm -v "$PWD:/repo" --workdir /repo rhysd/actionlint:1.7.12
```

The Docker profile runs on any Linux box with Docker (it creates
`/opt/netalertx` and `/opt/teamspeak` and starts both containers):

```bash
sudo PROVISION_PROFILE=docker bash ci/provision.sh "$PWD"
```

If you can run `systemd-nspawn` locally on a Linux host, you can approximate
the gate by hand:

```bash
sudo systemd-nspawn --directory=/mnt/raspi-root --boot --bind "$PWD:/workspace"
# inside the container:
cd /workspace && bash ci/provision.sh /workspace
```

The GitHub Actions workflow is the supported path though; the actions install
`systemd-container`, `qemu-user-static`, `binfmt-support` (and
`qemu-system-aarch64` for QEMU) automatically.

## Adding or changing tasks

- If a task gains a new interactive prompt, feed it via an env var in
  `run_setup()` in `ci/provision.sh`, or exclude it from CI (with a documented
  reason) like `tailscale`.
- If a task's verification needs a new service, container or port, extend the
  matching profile's `SERVICES`, `CONTAINERS` or `ENDPOINTS` list in
  `ci/provision.sh`. There is nothing to change in the workflow.
- Add a case to `ci/test-setup.sh` or `ci/test-lib.sh` for any new pure helper
  in `lib/common.sh`, `setup.sh` or `host/flash.sh`. Both scripts source the
  file under test, which is why `setup.sh` and `flash.sh` only call `main`
  when executed directly.
