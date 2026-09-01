#!/usr/bin/env bash
set -euo pipefail

# Patch homeassistant/helpers/translation.py to resolve [%key:X::Y::Z%] refs
# at cache-build time using homeassistant/strings.json.
#
# Problem:
#   HA pip packages ship translation files (e.g. switch/translations/en.json,
#   sensor/translations/en.json) with unresolved source-format references like
#   "[%key:common::state::off%]" instead of "Off". HA release builds resolve
#   these at compile time, but plain pip installs (used on Android/Termux) do not.
#   As a result the frontend displays raw keys like "[%key:common::state::off%]"
#   instead of human-readable strings such as "Off".
#
# Fix:
#   Patch _build_category_cache in translation.py to call _resolve_key_refs()
#   after recursive_flatten(), which substitutes [%key:X::Y::Z%] values with
#   the corresponding resolved strings from homeassistant/strings.json.
#   strings.json is loaded at module import time (before the async event loop)
#   to avoid blocking-I/O-in-event-loop warnings.
#
# Must be re-applied after every `pip install --upgrade homeassistant`.
#
# Usage:
#   ./provisioning/ssh/23_fix_ha_translation_keys.sh        # auto-detect via ADB
#   PHONE_HOST=192.168.x.x ./23_fix_ha_translation_keys.sh  # explicit host
#
# Optional env vars:
#   SKIP_RESTART=1   — skip HA restart after applying patch

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH_SCRIPT="${ROOT_DIR}/provisioning/ssh/23_fix_ha_translation_keys.py"

# ── Auto-detect PHONE_HOST ────────────────────────────────────────────────────
if [ -z "${PHONE_HOST:-}" ]; then
  echo "Auto-detecting PHONE_HOST via ADB..."
  PHONE_HOST="$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [ -n "${PHONE_HOST}" ] || PHONE_HOST="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 | tr -d '\r' || true)"
  [ -n "${PHONE_HOST}" ] || PHONE_HOST="$(adb shell ip -4 addr show wlan1 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 | tr -d '\r' || true)"
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi
[ -n "${PHONE_HOST:-}" ] || { echo "ERROR: could not detect PHONE_HOST" >&2; exit 1; }

HA_VENV="/data/data/com.termux/files/home/.venv"
HA_TRANS="${HA_VENV}/lib/python3.13/site-packages/homeassistant/helpers/translation.py"
STAGE="/data/local/tmp/ha_translation_patched.py"

# ── Write the Python patch script locally ────────────────────────────────────
cat > /tmp/ha_translation_patch.py << 'PYEOF'
"""Patch homeassistant/helpers/translation.py.
Applies [%key:X::Y::Z%] resolver at cache-build time using strings.json.
"""
import sys

src_path = sys.argv[1]
with open(src_path, "r") as f:
    content = f.read()

is_upgrade = False

if "_resolve_key_refs" in content:
    if "# v5: import-time-component-references" in content:
        print("SKIP: patch v5 already applied.")
        sys.exit(0)
    print("Upgrading patch to v5 (import-time component references)...")
    is_upgrade = True

if "_resolve_key_refs" in content:
    print("Updating existing patch (adding import-time load fix)...")
    # Remove old resolver block and replace with v3
    import re as _re
    old_block = _re.search(
        r"# ---- Android/Termux pip-install fix.*?# ---- End fix -{3,}\n\n",
        content,
        _re.DOTALL,
    )
    if old_block:
        content = content[: old_block.start()] + content[old_block.end() :]
    # Also remove import re added by old patch if not in original
    # (we'll re-add it below)

# 1. Add 'import re' if not present
if "\nimport re\n" not in content:
    content = content.replace(
        "import string\nfrom typing import Any",
        "import re\nimport string\nfrom typing import Any",
        1,
    )

# 2. Resolver block (injected before _load_translations_files_by_language)
RESOLVER = '''
# ---- Android/Termux pip-install fix ----------------------------------------
# HA pip packages ship translation files with unresolved [%key:X::Y::Z%] refs.
# HA release builds resolve these; plain pip installs do not, so the frontend
# shows raw keys like "[%key:common::state::off%]" instead of "Off".
# Resolved here at cache-build time via component translation files.
_KEY_RE = re.compile(r"\\[%key:([^%]+)%\\]")


def _load_component_reference_strings() -> dict[str, str]:
    """Load component strings for resolving references across cache categories."""
    try:
        import json as _json
        _components = pathlib.Path(__file__).parent.parent / "components"
        references: dict[str, str] = {}
        for component_dir in _components.iterdir():
            if not component_dir.is_dir():
                continue
            source = component_dir / "strings.json"
            if not source.is_file():
                continue
            raw = _json.loads(source.read_bytes().decode("utf-8"))
            references.update(
                recursive_flatten(f"component.{component_dir.name}.", raw)
            )
        return references
    except Exception:  # noqa: BLE001
        return {}


# Loaded once at import time — before the async event loop starts.
_COMPONENT_REFERENCE_STRINGS: dict[str, str] = _load_component_reference_strings()


def _resolve_key_refs(flat: dict[str, str]) -> dict[str, str]:
    """Replace [%key:X::Y::Z%] refs with human-readable strings.

    # v5: import-time-component-references

    Resolution order:
    1. Direct lookup in the category currently being built.
    2. Lookup in the bundled component source strings.
    """

    def _resolve(v: str, depth: int = 0) -> str:
        if depth > 3 or not isinstance(v, str) or not _KEY_RE.fullmatch(v):
            return v
        lookup = v[6:-2].replace("::", ".")
        if lookup in flat:
            return _resolve(flat[lookup], depth + 1)
        return _resolve(_COMPONENT_REFERENCE_STRINGS.get(lookup, v), depth + 1)

    return {k: _resolve(v) for k, v in flat.items()}

# ---- End fix ---------------------------------------------------------------

'''

if "\ndef _load_translations_files_by_language(" not in content:
    print("ERROR: insertion point not found in translation.py", file=sys.stderr)
    sys.exit(1)
content = content.replace(
    "\ndef _load_translations_files_by_language(",
    RESOLVER + "\ndef _load_translations_files_by_language(",
    1,
)

# 3. Call _resolve_key_refs after recursive_flatten in _build_category_cache
if not is_upgrade:
    MARKER = (
        "                flat = recursive_flatten(prefix, resource)\n"
        "                flat = self._validate_placeholders(language, flat, component_cache)"
    )
    REPLACEMENT = (
        "                flat = recursive_flatten(prefix, resource)\n"
        "                flat = _resolve_key_refs(flat)\n"
        "                flat = self._validate_placeholders(language, flat, component_cache)"
    )
    if MARKER not in content:
        print("ERROR: _build_category_cache marker not found", file=sys.stderr)
        sys.exit(1)
    content = content.replace(MARKER, REPLACEMENT, 1)
else:
    OLD_CALL = "                flat = _resolve_key_refs(language, flat)"
    NEW_CALL = "                flat = _resolve_key_refs(flat)"
    if OLD_CALL not in content:
        print("ERROR: existing _resolve_key_refs call not found", file=sys.stderr)
        sys.exit(1)
    content = content.replace(OLD_CALL, NEW_CALL, 1)

# Verify
assert "_resolve_key_refs(flat)" in content
assert "_COMPONENT_REFERENCE_STRINGS" in content
assert "_load_component_reference_strings" in content

with open(src_path, "w") as f:
    f.write(content)
print(f"Patched: {src_path}")
PYEOF

echo "Applying translation.py patch..."

# Stage the patch where the Termux app can read it, then run it as Termux.
# Android's root SELinux context cannot reliably access Termux private storage.
adb push /tmp/ha_translation_patch.py "${STAGE}" >/dev/null
adb shell "run-as com.termux /data/data/com.termux/files/usr/bin/sh -c 'backup_dir=/data/data/com.termux/files/home/.cache/provisioning; mkdir -p \"\$backup_dir\" && cp ${HA_TRANS} \"\$backup_dir/translation.py.$(date +%Y%m%d-%H%M%S).bak\" && /data/data/com.termux/files/home/.venv/bin/python ${STAGE} ${HA_TRANS}'"
adb shell "rm -f ${STAGE}"
echo "translation.py patched on device."

# Clean up temp files
rm -f /tmp/ha_translation_patch.py

# ── Restart HA ────────────────────────────────────────────────────────────────
if [ "${SKIP_RESTART:-0}" = "1" ]; then
  echo "SKIP_RESTART=1 — skipping HA restart."
else
  echo "Restarting Home Assistant..."
  # TMPDIR must point inside Termux's writable tree so 'sh' can create heredoc
  # temp files (<<EOF blocks in hassctl.sh). Without it, adb shell uses the
  # system /data/local/tmp which is root-only, causing "Permission denied".
  TERMUX_HOME="/data/data/com.termux/files/home"
  TERMUX_BIN="/data/data/com.termux/files/usr/bin"
  TERMUX_TMP="/data/data/com.termux/files/usr/tmp"
  adb shell "run-as com.termux env TMPDIR=${TERMUX_TMP} HOME=${TERMUX_HOME} ${TERMUX_BIN}/sh ${TERMUX_HOME}/scripts/hassctl.sh restart" || true
  echo "HA restart triggered."
fi

echo ""
echo "=== Done ==="
echo "The [%key:common::state::off%] display issue should now be resolved."
echo "Re-run this script after every 'pip install --upgrade homeassistant'."
