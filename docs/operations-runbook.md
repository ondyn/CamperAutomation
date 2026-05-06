# CamperAutomation Operations Runbook

This runbook is for incident response and recovery on the camper Android + Termux Home Assistant stack.

## Scope

- Android phone host with Termux and Termux:Boot.
- Tailscale userspace networking.
- SSH remote access.
- Home Assistant Core runtime.
- ESPHome connectivity from van hotspot.

## P0: Complete Remote Access Loss

Symptoms:

- Home Assistant Companion cannot connect over VPN.
- SSH unreachable.

Checks:

```sh
pgrep -fa tailscaled
ls -l $PREFIX/var/run/tailscale/tailscaled.sock
/data/data/com.termux/files/home/vpn/tailscale --socket $PREFIX/var/run/tailscale/tailscaled.sock status
pgrep -x sshd
```

Recovery:

```sh
sh /data/data/com.termux/files/home/scripts/bootstrap_services.sh
```

Success signal:

- `tailscale status` returns peers.
- `sshd` process exists.

## P0: Home Assistant Down

Symptoms:

- Companion app fails while VPN/SSH are healthy.

Checks:

```sh
screen -ls
pgrep -fa "hass|homeassistant"
tail -n 200 /data/data/com.termux/files/home/.suroot/.homeassistant/home-assistant.log
```

Recovery:

```sh
/data/data/com.termux/files/home/scripts/hassctl.sh restart
```

Success signal:

- `screen -ls` includes `.hass`.
- HA log shows normal startup and API availability.

## P1: ESPHome Devices Offline

Symptoms:

- ESP entities become unavailable after hotspot cycle.

Checks:

```sh
ping -c 3 esphymer.local
tail -n 100 /data/data/com.termux/files/home/.suroot/.homeassistant/home-assistant.log
```

Recovery:

- Ensure HA ESPHome integration host uses mDNS hostname (example: `esphymer.local`) rather than dynamic IP.
- Reboot ESP node if mDNS does not recover.

Success signal:

- Ping resolves and entities return.

## P1: Storage Pressure / DB Growth

Checks:

```sh
df -h
du -h /data/data/com.termux/files/home/.suroot/.homeassistant | sort -h | tail -n 20
du -h /data/data/com.termux/files/home/.suroot/.homeassistant/home-assistant_v2.db
```

Recovery:

- Purge old recorder history from Home Assistant settings.
- Remove stale logs and backups after copying if needed.

## P1: CPU Pressure / Thermal Throttling

Checks:

```sh
top -n 1 | head -n 25
ps -eo pid,pcpu,pmem,args | sort -k2 -nr | head -n 15
```

Recovery:

- Reduce high-frequency sensors and automation loops.
- Lower noisy debug logging once root cause is known.

## P1: Tilt Meter Unavailable

Symptoms:

- `termux_tilt` entities show unavailable.
- Home Assistant log reports `termux-sensor failed` or `accelerometer data was not present`.

Checks:

```sh
command -v termux-sensor
dpkg-query -W -f='${Package} ${Version}\n' termux-api
pm list packages | grep com.termux.api
```

Recovery:

- Install or reinstall the Android app `Termux:API`.
- In Termux, run `pkg install termux-api`.
- Restart Home Assistant after both layers are present.

Success signal:

- `command -v termux-sensor` returns a path.
- `termux_tilt` sensors update after `button.sample_once` or `termux_tilt.sample_once`.

## Package / Install Failures (pip, uv, native wheels)

Checks:

```sh
python3 --version
pip --version
uv --version
pkg list-installed | grep -E "python|rust|clang|libxml2|libxslt|libffi|jpeg|png"
```

Recovery approach:

- Prefer `pkg install uv` over `pip install uv` on Termux.
- Recreate venv when dependency state is inconsistent.
- Install missing native dependencies from Termux packages before retrying pip/uv.

## Reboot Recovery Validation Checklist

Run after device restart:

```sh
tail -n 200 /data/data/com.termux/files/home/logs/bootstrap.log
pgrep -fa tailscaled
pgrep -x sshd
screen -ls
```

Expected:

- Bootstrap log shows VPN -> SSH -> HA sequence.
- Tailscale daemon, SSH daemon, and HA screen session are present.
