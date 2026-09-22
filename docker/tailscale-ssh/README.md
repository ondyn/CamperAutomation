# Tailscale SSH helper

This folder runs a Tailscale client in Docker so the MacBook can join the same tailnet without installing a system VPN client.

Required environment values:

- `TS_AUTHKEY`: a reusable Tailscale auth key from the tailnet admin
- `SSH_PWD`: password for the phone's Termux SSH service from the repo root `.env`

Example:

```bash
cd docker/tailscale-ssh
export TS_AUTHKEY="TSKEY-..."
docker compose up -d

docker compose exec ssh-client sh
sshpass -p "$SSH_PWD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p <PORT> u0_a<USER>@<IP>
```

If the phone is already reachable on the tailnet, the SSH target is the phone's fixed IP.

Note: without a valid `TS_AUTHKEY`, the container will remain unauthenticated and cannot reach the phone over Tailscale.
