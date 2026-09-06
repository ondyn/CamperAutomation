"""Patch homeassistant/helpers/translation.py to resolve [%key:X::Y::Z%] refs.

Problem:
    HA pip packages ship translation files (e.g. switch/translations/en.json)
    with unresolved source-format references like "[%key:common::state::off%]"
    instead of "Off". HA release builds resolve these at compile time, but
    plain pip installs (used on Android/Termux) do not, so the frontend shows
    the raw key text instead of the human-readable string.

Fix:
    Patch _build_category_cache() to call _resolve_key_refs() after
    recursive_flatten(), substituting [%key:X::Y::Z%] values using two
    sources: the root homeassistant/strings.json (holds "common.*" keys such
    as common.state.off) and every homeassistant/components/*/strings.json
    (holds "component.<domain>.*" keys). Both are loaded once at import time
    (before the async event loop starts) to avoid blocking-I/O warnings.

Canonical, versioned patch: re-running this on an already-patched file is a
no-op; re-running it on a file patched by an older version of this script
strips the old block and reapplies the current one.

Usage:
    python ha_translation_patch.py /path/to/homeassistant/helpers/translation.py

Must be re-applied after every 'pip install --upgrade homeassistant' (a fresh
venv/site-packages wipes the patch).
"""

import re
import sys

VERSION_MARKER = "# translation-patch-version: 6"

src_path = sys.argv[1]
with open(src_path, "r") as f:
    content = f.read()

if VERSION_MARKER in content:
    print("SKIP: patch v6 already applied.")
    sys.exit(0)

# Strip any older version of this patch block (v3/v4/v5 lacked the root
# homeassistant/strings.json lookup, so "common::" refs like
# "[%key:common::state::off%]" never resolved).
old_block = re.search(
    r"\n*# ---- Android/Termux pip-install fix.*?# ---- End fix -{3,}\n+",
    content,
    re.DOTALL,
)
if old_block:
    content = content[: old_block.start()] + "\n\n" + content[old_block.end():]
    # Revert a previously-patched call site back to the pristine form so the
    # marker-based insertion below matches unconditionally.
    content = content.replace(
        "                flat = recursive_flatten(prefix, resource)\n"
        "                flat = _resolve_key_refs(flat)\n"
        "                flat = self._validate_placeholders(language, flat, component_cache)",
        "                flat = recursive_flatten(prefix, resource)\n"
        "                flat = self._validate_placeholders(language, flat, component_cache)",
    )
    print("Removed previous translation-key patch; reapplying current version...")

if "\nimport re\n" not in content:
    content = content.replace(
        "import string\nfrom typing import Any",
        "import re\nimport string\nfrom typing import Any",
        1,
    )

RESOLVER = '''
''' + VERSION_MARKER + '''
# ---- Android/Termux pip-install fix ----------------------------------------
# HA pip packages ship translation files with unresolved [%key:X::Y::Z%] refs.
# HA release builds resolve these; plain pip installs do not, so the frontend
# shows raw keys like "[%key:common::state::off%]" instead of "Off".
# Resolved here at cache-build time via the root homeassistant/strings.json
# (holds "common.*" keys) and every homeassistant/components/*/strings.json
# (holds "component.<domain>.*" keys).
_KEY_RE = re.compile(r"\\[%key:([^%]+)%\\]")


def _load_reference_strings() -> dict[str, str]:
    """Load root + component strings for resolving cross-file references."""
    try:
        import json as _json
        package_dir = pathlib.Path(__file__).parent.parent
        references: dict[str, str] = {}

        root_strings = package_dir / "strings.json"
        if root_strings.is_file():
            raw = _json.loads(root_strings.read_bytes().decode("utf-8"))
            references.update(recursive_flatten("", raw))

        components_dir = package_dir / "components"
        for component_dir in components_dir.iterdir():
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
_REFERENCE_STRINGS: dict[str, str] = _load_reference_strings()


def _resolve_key_refs(flat: dict[str, str]) -> dict[str, str]:
    """Replace [%key:X::Y::Z%] refs with human-readable strings.

    Resolution order:
    1. Direct lookup in the category currently being built.
    2. Lookup in the bundled root/component source strings.
    """

    def _resolve(v: str, depth: int = 0) -> str:
        if depth > 3 or not isinstance(v, str) or not _KEY_RE.fullmatch(v):
            return v
        lookup = v[6:-2].replace("::", ".")
        if lookup in flat:
            return _resolve(flat[lookup], depth + 1)
        return _resolve(_REFERENCE_STRINGS.get(lookup, v), depth + 1)

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

# Verify
assert VERSION_MARKER in content
assert "_resolve_key_refs(flat)" in content
assert "_REFERENCE_STRINGS" in content
assert "_load_reference_strings" in content

with open(src_path, "w") as f:
    f.write(content)
print(f"Patched: {src_path}")
