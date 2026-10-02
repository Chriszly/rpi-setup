# firewall - nftables

An opt-in firewall that lets in SSH and the ports of the rpi-setup services
installed on this Pi, and drops everything else that comes in.

```bash
sudo bash setup.sh firewall
```

**Run it last**, and run it again after installing another task so that
task's ports are opened. It looks at what is installed when it runs.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `FIREWALL_SSH_PORT` | `22` | SSH port, always allowed. Every port sshd really listens on is allowed too, so a wrong value cannot lock you out. |
| `FIREWALL_AUTO_PORTS` | `yes` | Open the ports of the installed rpi-setup services (table below). `no`: only SSH and `FIREWALL_EXTRA_PORTS`. |
| `FIREWALL_EXTRA_PORTS` | none | More ports open to anyone, as `port/proto` or `from-to/proto`, e.g. `8123/tcp 1900/udp`. |
| `FIREWALL_ALLOW_FROM` | empty: anyone | Subnets allowed to reach the web UIs, e.g. `192.168.1.0/24`; several separated by spaces. Tailscale is always allowed. |

## What gets opened

Always allowed: SSH, ping, loopback, everything over Tailscale
(`tailscale0`, if you installed it yourself), Docker's networks, mDNS (`<host>.local`) and replies to
connections the Pi started.

| Service (when installed, natively or in its container) | Ports | Who may connect |
|--------------------------|-------|-----------------|
| Pi-hole DNS | 53/tcp, 53/udp | anyone |
| Pi-hole DHCP (when its DHCP server is on) | 67/udp, 547/udp for IPv6 | anyone |
| Pi-hole admin | its web port (80 or 8080) | `FIREWALL_ALLOW_FROM` |
| nginx (`web`) | its listen ports | `FIREWALL_ALLOW_FROM` |
| NetAlertX | `NETALERTX_PORT` and 20212 (its API) | `FIREWALL_ALLOW_FROM` |
| TeamSpeak | voice, file and query ports | anyone |
| Samba | 445/tcp, 139/tcp, 137/udp, 138/udp | anyone |
| Tailscale (installed by hand) | 41641/udp | anyone |

## What it installs

- `nftables` (if `nft` is missing).
- `/etc/rpi-setup/firewall.nft`, the rules, in their own table
  `inet rpi_setup`. Docker's and Tailscale's tables are left alone. The rules
  are checked with `nft -c` before anything is loaded.
- `rpi-setup-firewall.service`, which loads the table at boot.

## Using it

```bash
sudo nft list table inet rpi_setup                  # show the rules
sudo systemctl disable --now rpi-setup-firewall     # turn it off
```

## Ports of Docker containers

Ports a container publishes (`ports:` in its compose file) are forwarded by
Docker before these rules see them, so the firewall does not limit them. The
task lists them when it runs. Only TeamSpeak publishes ports: the other
containers use the host network, so the rules above apply to them.

To close or limit such a port:

- **Turn off what uses it.** `TEAMSPEAK_QUERY_HTTP=no` and
  `sudo bash setup.sh teamspeak` stop publishing the web query port (10080).
  The voice and file ports are needed by every TeamSpeak client.
- **Keep it inside your network.** A port is only reachable from the
  internet if your router forwards it to the Pi; without a port forward it
  stays in your LAN (and Tailscale, if you installed it yourself).
- **Do not edit `/opt/teamspeak/docker-compose.yml` by hand**: the task
  rewrites it on its next run.
- **Limit who may connect** with a rule in Docker's `DOCKER-USER` chain,
  which Docker checks before forwarding. For example, allow the query port
  only from your LAN:

  ```bash
  sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 10080 ! -s 192.168.1.0/24 -j DROP
  ```

  rpi-setup does not manage this rule and it is gone after a reboot unless
  you save it (for example with the `iptables-persistent` package). See
  [Docker's packet filtering docs](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

## Good to know

- Services running in their own container (`<TASK>_DOCKER=yes`) are
  detected like native ones; they use the host network, so these rules apply
  to them.
- Inside a container or CI the rules are generated and checked but not loaded.
