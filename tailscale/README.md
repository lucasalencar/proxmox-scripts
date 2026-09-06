# Tailscale Subnet Router

Dedicated minimal LXC (`tailscale-router`) that advertises the home LAN to the tailnet, so local URLs keep working remotely over VPN. No inbound ports are opened on the router; no service is published to the public Internet by this package.

## References

- [Tailscale Subnet routers](https://tailscale.com/kb/1019/subnets)
- [Tailscale DNS](https://tailscale.com/kb/1054/dns)
- `docs/tailscale-plan.md` (full phased plan: install, split DNS, ACLs, onboarding)

## Install

```bash
bash tailscale/install.sh
```

See `tailscale/install.sh` for what each step does.

## Update

```bash
bash tailscale/update.sh
```

See `tailscale/update.sh` for details.

## Ports & Caddy

This package exposes nothing publicly and must be excluded from automatic Caddy publishing (tag `tailscale,router`, single-purpose guest). Remote access happens only through the tailnet; see `docs/tailscale-plan.md` for the deny-by-default ACL model.

## Folder Structure

```
tailscale/
├── install.sh              # host: create/reuse LXC, TUN passthrough, push provision.sh
├── update.sh               # host: push container/upgrade.sh
├── container/
│   ├── provision.sh        # guest: install tailscale, enable forwarding + tailscaled
│   └── upgrade.sh          # guest: refresh tailscale package, restart + check service
└── README.md
```

`container/upgrade.sh` is intentionally not named `update.sh` so the recursive root `update.sh` never executes it on the host.

## Post-Install Steps

Login is manual and never automated (no auth keys or tokens in scripts):

```bash
CTID=$(pct list | grep -i tailscale-router | awk '{print $1}')
pct exec "$CTID" -- tailscale up
pct exec "$CTID" -- tailscale set --advertise-routes=<LAN-CIDR>
```

Then approve the route in the Tailscale admin console. Full verification checklist: `docs/tailscale-plan.md`.

## Verification

```bash
CTID=$(pct list | grep -i tailscale-router | awk '{print $1}')
pct config "$CTID" | grep -E "lxc.cgroup2.devices.allow|lxc.mount.entry"
pct exec "$CTID" -- ls -l /dev/net/tun
pct exec "$CTID" -- systemctl is-active tailscaled
```

## Resources

- Default: 1 core / 512 MB / 8 GB. Adjust `CT_CORES`/`CT_MEMORY`/`CT_DISK`/`CT_SWAP` in `tailscale/install.sh` if needed.
