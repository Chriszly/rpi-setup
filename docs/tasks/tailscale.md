# tailscale - VPN

Installs [Tailscale](https://tailscale.com/), a WireGuard mesh VPN, so you can
reach the Pi from anywhere without opening ports on your router.

```bash
sudo bash setup.sh tailscale
```

The task runs Tailscale's official installer (`curl https://tailscale.com/install.sh | sh`)
and prints a warning first. Without an auth key, `tailscale up` prints a login
URL: open it in a browser to add the Pi to your tailnet.

## Settings

An empty setting adds no flag, so a re-run never undoes something you set
by hand with `tailscale set`.

| Setting | Default | Meaning |
|---------|---------|---------|
| `TAILSCALE_DOCKER` | `no` | `yes` runs Tailscale in a Docker container instead of the native package. Not recommended ([below](#run-it-in-docker)). |
| `TAILSCALE_IMAGE` | `tailscale/tailscale:latest` | Docker image for `TAILSCALE_DOCKER=yes`. |
| `TAILSCALE_AUTHKEY` | empty: print a login URL | Auth key from <https://login.tailscale.com/admin/settings/keys> for an unattended login. |
| `TAILSCALE_HOSTNAME` | the Pi's host name | Name of this Pi in your tailnet. |
| `TAILSCALE_SSH` | leave as it is | `yes`/`no`: Tailscale SSH. |
| `TAILSCALE_ADVERTISE_EXIT_NODE` | leave as it is | `yes`/`no`: offer this Pi as an exit node (turns on IP forwarding). |
| `TAILSCALE_ADVERTISE_ROUTES` | leave as it is | LAN subnets to reach through this Pi, comma separated, e.g. `192.168.1.0/24` (turns on IP forwarding). |
| `TAILSCALE_ACCEPT_DNS` | `yes`, but `no` on a Pi with Pi-hole | `yes`/`no`: use the tailnet's DNS settings (MagicDNS). On a Pi that runs Pi-hole it is turned off, so the Pi does not resolve names through itself. |

## What it installs and changes

- The `tailscale` package (Tailscale's apt repository) and the `tailscaled`
  service, enabled and started.
- `/etc/sysctl.d/99-tailscale.conf` with IP forwarding, only when you
  advertise routes or an exit node.
- On a Pi that is already logged in, changed settings are applied with
  `tailscale set`.

## Run it in Docker

With `TAILSCALE_DOCKER=yes` the task runs Tailscale's official image
(`TAILSCALE_IMAGE`) in a container named `tailscale` on the host network with
`/dev/net/tun`, so `tailscale0`, subnet routes and the exit node work as they
do natively. Docker is installed first if it is missing.

- **Native is recommended**: Tailscale is often your way in from outside, and
  in a container it goes down whenever Docker does. Tailscale SSH cannot work
  from a container, so the task refuses `TAILSCALE_SSH=yes` there.
- State lives in `/opt/tailscale/state`. A native tailscaled is stopped and its
  state copied once, so the Pi keeps its node and needs no new login.
- Without an auth key the task prints the login URL (later: `docker logs tailscale`).
  Use `docker exec tailscale tailscale status` instead of `tailscale status`.
- `TAILSCALE_DOCKER=no` stops the container and brings the native tailscaled back.

## Good to know

- Approve advertised routes and exit nodes in the Tailscale admin console.
- Run `pihole` before `tailscale` (or re-run `tailscale` afterwards) so the
  automatic `TAILSCALE_ACCEPT_DNS` choice sees Pi-hole.
- With the `firewall` task, traffic over `tailscale0` is always allowed and
  UDP 41641 is opened for direct connections.
- Status: `tailscale status`. Log out: `sudo tailscale logout`. Remove:
  `sudo apt purge tailscale`.
