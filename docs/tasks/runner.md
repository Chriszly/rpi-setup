# runner - manual "Deploy to Pi" from your private repository

Lets you update the Pi from GitHub with a button: a **private** repository of
yours holds your settings and a *Deploy to Pi* workflow, and a GitHub Actions
runner on the Pi runs it. Pressing *Run workflow* pulls this public repo on the
Pi, installs your settings and reruns the tasks you pick. Nothing runs on its
own, nothing connects in to the Pi, and GitHub stores no SSH key, Tailscale
key or Pi address.

```bash
sudo RUNNER_TOKEN=<token> bash setup.sh runner
```

The private repository's layout, workflow and step-by-step setup are in
[templates/private-repo/README.md](../../templates/private-repo/README.md).

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `RUNNER_REPO` | none (required) | Your private repository as `owner/name`, e.g. `Chriszly/rpi-private`. Never a public one. |
| `RUNNER_TOKEN` | empty | One-time registration token: in the private repository open *Settings > Actions > Runners > New self-hosted runner* and copy the value after `--token`. Valid for one hour; not needed once the runner is registered. |
| `RUNNER_NAME` | the Pi's hostname | Runner name shown at GitHub. |
| `RUNNER_LABELS` | `RUNNER_NAME` | Comma separated labels; the workflow's *pi* input picks the Pi by one of them and reads `pis/<pi>/rpi-setup.env`. |
| `RUNNER_BRANCHES` | `main` | Branches of this repository a deploy may switch the Pi to. |

## What it installs

- System user `rpi-runner` (stable UID via `assign_uid`) and the newest
  GitHub Actions runner in `/opt/rpi-runner`, checked against the SHA-256
  GitHub publishes, running as a systemd service. It updates itself.
- `/usr/local/sbin/rpi-setup-deploy`, the only command `rpi-runner` may run as
  root (`/etc/sudoers.d/rpi-setup-runner`). It accepts `--branch` (only from
  `RUNNER_BRANCHES`), `--config` (a file the caller can read) and `--tasks`
  (names of `tasks/<name>.sh` in the checkout; nothing starting with `-`).
- `setup.sh` records every task that finished in
  `/var/lib/rpi-setup/tasks.done`; a deploy with no tasks reruns those.

## What a deploy does

1. Fast-forwards this repository's checkout on the Pi to the chosen branch.
2. Installs `pis/<pi>/rpi-setup.env` from the private repository as
   `/etc/rpi-setup/rpi-setup.env` (root, 0600), if the workflow's *settings*
   box is ticked.
3. Runs `setup.sh` with the chosen tasks, as if the owner of the checkout
   had started it with sudo (`SUDO_USER`), so tasks that set up "your" user
   (docker group, SSH keys, Samba user) pick that person and never
   `rpi-runner`. Only the run summary goes to the
   workflow log; the full output, which can contain generated passwords,
   stays on the Pi in `/var/log/rpi-setup-deploy/`.
4. Deletes the private repository's checkout from the Pi.

You can run the same deploy by hand on the Pi:
`sudo /usr/local/sbin/rpi-setup-deploy --tasks "base pihole"`.

## Pitfalls

- Anyone who can run workflows in the private repository can run `setup.sh`
  as root on the Pi. Keep it private and keep two-factor login on GitHub.
- A runner on a public repository would let pull requests from strangers run
  code on the Pi. Make sure `RUNNER_REPO` names a private repository.
- A deploy stops if the checkout on the Pi has local commits or changes
  (`git -C <checkout> status`).
- The checkout must belong to your own login user, not `root` or
  `rpi-runner`; otherwise a deploy stops (`sudo chown -R <you>: <checkout>`).
- A deploy reads `/etc/rpi-setup/rpi-setup.env`. If your settings are still
  in the checkout's `config/rpi-setup.env` and the deploy brings none
  (*settings* box not ticked, no `--config`), it stops instead of running
  every task with defaults. Move them once:
  `cd <checkout> && sudo bash setup.sh --move-config`.
- Remove the runner: `cd /opt/rpi-runner && sudo ./svc.sh uninstall`, then
  delete it at *Settings > Actions > Runners* in the private repository.
