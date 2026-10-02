# Raspberry Pi 5 test checklist

rpi-setup is tested in CI (containers and a QEMU VM), but not yet on a real
Raspberry Pi 5. This page walks you through one full test run. It takes about
an hour, most of it waiting. At the end you paste a few outputs back into the
issue or pull request, so note anything odd as you go.

You need: a Raspberry Pi 5, a microSD card (16 GB or more), the official
5V/5A USB-C power supply if you have one, a network cable or Wi-Fi details,
and a Linux or Windows PC.

## 1. Flash the card

- Linux: follow [docs/setup-linux.md](setup-linux.md) (`host/flash.sh`).
- Windows: follow [docs/setup-windows.md](setup-windows.md) (`host/flash.ps1`).

Write down which one you used and the image it picked (Raspberry Pi OS Lite
64-bit, Trixie or Bookworm).

## 2. First boot

Put the card in the Pi, connect the network, power it on and note the time.

- [ ] How long until you can log in with `ssh <user>@<hostname>.local` (or the IP)?
- [ ] Does the user you chose while flashing exist and can it use `sudo`?
- [ ] Does SSH work with your key or password as expected?

## 3. Get rpi-setup and fill in the settings

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/Chriszly/rpi-setup.git
cd rpi-setup
bash setup.sh --init-config
nano config/rpi-setup.env
```

If the repository is private, clone as shown in Step 4 of
[docs/setup-linux.md](setup-linux.md). Fill in what you want to test (see the
comments in the file).

## 4. Run all tasks

```bash
sudo bash setup.sh base docker samba web pihole netalertx teamspeak 2>&1 | tee ~/run1.log
```

- [ ] Did every task end with `[+] Complete: <task>`?
- [ ] How long did the run take?

## 5. Reboot and check

```bash
sudo reboot
# log in again, then:
cd rpi-setup
sudo bash check.sh | tee ~/check1.txt
```

`check.sh` changes nothing. It prints one line per check (OK, WARN or FAIL)
and a summary. Also open the web pages it lists from another PC on your
network (the nginx page, Pi-hole admin, NetAlertX).

## 6. Re-run everything (idempotency)

```bash
sudo bash setup.sh base docker samba web pihole netalertx teamspeak 2>&1 | tee ~/run2.log
sudo bash check.sh | tee ~/check2.txt
```

- [ ] Did the second run finish without errors and without asking anything new?
- [ ] Is `check2.txt` as good as `check1.txt`?

## 7. What to paste back

1. `~/check1.txt` and `~/check2.txt` (the full `check.sh` output).
2. Any `[!]` or `[x]` lines from `~/run1.log` and `~/run2.log`
   (`grep -E '\[!\]|\[x\]' ~/run*.log`), or the whole logs if something failed.
3. Errors from this boot, if any: `journalctl -b -p err --no-pager | tail -n 50`.
4. Your notes from steps 1 to 6: flash tool, first boot time, run times, and
   anything that surprised you.

Please look over what you paste: `check.sh` never prints passwords, but the
run logs contain generated passwords (for example the Samba one) if you did
not set your own. Remove those lines before pasting.

Thank you!
