# DNS Resolution Fix for HACS on Termux/Android

## Problem
Home Assistant on rooted Android (Termux) could not resolve DNS for HACS and homeassistant_alerts due to aiodns (c-ares) resolver failures:
- Error: `Cannot connect to host github.com:443 ssl:default [Could not contact DNS servers]`
- Root cause: aiodns/c-ares resolver is non-functional in Termux app UID namespace

## Root Cause Analysis
1. **Socket DNS (libc) works**: Direct Python `socket.getaddrinfo()` resolves hostnames correctly
2. **aiodns/c-ares fails**: aiodns module cannot reach DNS servers despite proper /etc/resolv.conf configuration
3. **Platform issue**: c-ares has known permission/namespace issues in Android app containers
4. **Tailscale not involved**: Disabling Tailscale confirmed it was not the blocker

## Solution: Block aiodns, Force ThreadedResolver

### Changes Made

**File: [scripts/hass.sh](scripts/hass.sh)**
- Modified Home Assistant launcher to install `sitecustomize.py` in Python's site-packages
- sitecustomize.py uses Python's import system to:
  1. **Block aiodns**: Raise ImportError if any code tries to import aiodns/aiohttp_asyncmdnsresolver
  2. **Force ThreadedResolver**: aiohttp automatically falls back to ThreadedResolver (libc-based) when aiodns is unavailable
  3. **Cleanup existing imports**: Remove any cached aiodns modules from sys.modules at startup

### Technical Details

The fix injects a Python import hook before Home Assistant starts:

```python
class AioдnsBlocker(importlib.abc.Loader):
    def create_module(self, spec):
        raise ImportError("aiodns is not functional on Termux/Android")

class AioдnsFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if 'aiodns' in fullname or 'asyncmdnsresolver' in fullname:
            return ModuleSpec(fullname, AioдnsBlocker())
        return None

sys.meta_path.insert(0, AioдnsFinder())
```

**Result**: When aiohttp or any component tries to use aiodns, it gets an ImportError and automatically falls back to `ThreadedResolver`, which uses libc's `getaddrinfo()` (which works on Termux).

## Deployment

1. Updated [scripts/hass.sh](scripts/hass.sh) with the aiodns blocker
2. Updated [scripts/hassctl.sh](scripts/hassctl.sh) with gateway-aware DNS resolver generation
3. Deployed to phone via `adb push` and restarted HA

## Verification

**PASS**: Direct aiohttp test to GitHub endpoint:
```bash
aiohttp.ClientSession().get('https://github.com') → Status 200
```

**Partial**: Home Assistant integration tests:
- HACS: Still shows warnings but can attempt connection
- homeassistant_alerts: DNS error persists (may need separate fix or component disable)

## Remaining Issues

- homeassistant_alerts component still shows DNS error on early startup
  - **Workaround**: Disable homeassistant_alerts in configuration.yaml if not needed
  - May require deeper investigation of how homeassistant_alerts creates its aiohttp client

## Files Modified

- [scripts/hass.sh](scripts/hass.sh) - Main fix: aiodns blocker in sitecustomize.py
- [scripts/hassctl.sh](scripts/hassctl.sh) - Gateway-aware DNS resolver generation

## Testing Commands (Run on Termux)

```bash
# Test aiодns is blocked
~/.venv/bin/python -c "import aiodns" 2>&1

# Test aiohttp DNS resolution works
~/.venv/bin/python -c "import asyncio,aiohttp; asyncio.run(aiohttp.ClientSession().get('https://github.com').__aenter__().then(lambda r: print(r.status)))"

# View Home Assistant logs for DNS errors
tail -n 200 ~/.homeassistant/home-assistant.log | grep -Ei "dns|github|alerts|hacs"
```

## Future Improvements

1. **Enable aiodns blocker earlier** in Python startup chain if needed for other components
2. **Custom DNS config** for specific integrations if they hardcode resolver paths
3. **Monitor for HA updates** that might change resolver initialization paths
