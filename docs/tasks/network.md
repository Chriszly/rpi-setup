# network - fixed LAN address

Gives the Pi a fixed IPv4 address on your LAN through NetworkManager (the
default on Raspberry Pi OS Bookworm and Trixie). Pi-hole, bookmarks and port
forwards need the Pi's address to stay the same.

```bash
sudo bash setup.sh network
```

With `NETWORK_STATIC_IP` empty the task changes nothing: it prints the current
address and MAC so you can reserve the address in your router instead (the
simplest option when your router supports it).

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `NETWORK_STATIC_IP` | empty: keep DHCP | Fixed address with prefix, e.g. `192.168.1.10/24`. Pick one outside your router's DHCP range. |
| `NETWORK_INTERFACE` | the default route's | Interface to configure, e.g. `eth0` or `wlan0`. |
| `NETWORK_GATEWAY` | the current default gateway | Your router, e.g. `192.168.1.1`. Must be inside the `NETWORK_STATIC_IP` subnet. |
| `NETWORK_DNS` | the gateway | DNS servers, comma separated. `127.0.0.1` lets the Pi use its own Pi-hole (only once `pihole` is installed). |

## What it changes

The active NetworkManager connection on the interface gets `ipv4.method
manual` with the address, gateway and DNS above, then is re-activated. Nothing
else is touched. All settings are checked before anything changes.

## Good to know

- **Over SSH the session drops** when the address changes. Run this task alone
  or last, then reconnect with `ssh <user>@<new address>`. Tasks listed after
  `network` in the same run do not run; start them again after reconnecting.
- With Pi-hole installed, point your router's DNS setting at the new address.
- Back to DHCP (the task prints this command with your connection name):

  ```bash
  sudo nmcli connection modify <connection> ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns ''
  sudo nmcli connection up <connection>
  ```

- Inside a container or CI the task only prints the `nmcli` commands it would run.
