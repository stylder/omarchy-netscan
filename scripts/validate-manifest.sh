#!/usr/bin/env bash
# Validate this plugin folder against the Omarchy plugin manifest schema.
#
# This mirrors the checks in Omarchy's own `omarchy-plugin-validate`, so the
# repository can be checked without installing Omarchy. The shell runs the
# same rules when it loads a plugin, and `omarchy plugin add` refuses to
# install anything that fails them.

set -uo pipefail

PLUGIN_DIR="${1:-.}"
cd "$PLUGIN_DIR" || {
  echo "validate-manifest: no such directory: $PLUGIN_DIR" >&2
  exit 1
}

fail() {
  echo "validate-manifest: $*" >&2
  exit 1
}

MANIFEST="manifest.json"
[[ -f $MANIFEST ]] || fail "missing $MANIFEST in $PLUGIN_DIR"
jq -e . "$MANIFEST" >/dev/null 2>&1 || fail "$MANIFEST is not valid JSON"

jq -e '.schemaVersion == 1' "$MANIFEST" >/dev/null 2>&1 \
  || fail "unsupported or missing schemaVersion (expected 1)"

for field in id name version kinds entryPoints; do
  jq -e --arg f "$field" 'has($f)' "$MANIFEST" >/dev/null 2>&1 \
    || fail "manifest missing required field '$field'"
done

ID=$(jq -r '.id // ""' "$MANIFEST")
[[ -n $ID ]] || fail "manifest 'id' is empty"
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid plugin id '$ID'"
[[ $ID != *".."* ]] || fail "invalid plugin id '$ID'"
[[ $ID != omarchy.* ]] || fail "plugin id '$ID' uses the reserved omarchy.* namespace"

jq -e '(.kinds | type) == "array" and (.kinds | length) > 0' "$MANIFEST" >/dev/null 2>&1 \
  || fail "'kinds' must be a non-empty array"

jq -e '(.entryPoints | type) == "object"' "$MANIFEST" >/dev/null 2>&1 \
  || fail "'entryPoints' must be an object"

jq -e '
  if ((.barWidget? | type) == "object" and (.barWidget | has("defaultSection"))) then
    .barWidget.defaultSection as $section
    | ($section | type) == "string"
      and (["left", "center", "right"] | index($section)) != null
  else
    true
  end
' "$MANIFEST" >/dev/null 2>&1 \
  || fail "'barWidget.defaultSection' must be left, center, or right"

# Every entry point has to be a relative path inside the plugin folder.
while IFS= read -r ep; do
  [[ -n $ep ]] || continue
  [[ $ep != /* ]] || fail "entry point must be a relative path: '$ep'"
  [[ $ep != *".."* ]] || fail "entry point may not contain '..': '$ep'"
  [[ -f $ep ]] || fail "entry point file not found: '$ep'"
done < <(jq -r '.entryPoints | to_entries[].value' "$MANIFEST")

# A kind that promises something to load has to name the entry point the
# shell will look for, or the plugin installs and does nothing.
for kind_entry_point in \
  "bar:bar" \
  "bar-widget:barWidget" \
  "menu:menu" \
  "overlay:overlay" \
  "panel:panel" \
  "service:service"; do
  kind="${kind_entry_point%%:*}"
  entry_point="${kind_entry_point##*:}"
  jq -e --arg kind "$kind" '(.kinds | index($kind)) != null' "$MANIFEST" >/dev/null 2>&1 || continue
  jq -e --arg ep "$entry_point" '.entryPoints | has($ep)' "$MANIFEST" >/dev/null 2>&1 \
    || fail "kind '$kind' requires an 'entryPoints.$entry_point' to load"
done

# Symlinks could point a copied plugin at arbitrary files on disk.
link=$(find . -name .git -prune -o -type l -print -quit 2>/dev/null)
[[ -z $link ]] || fail "symlinks are not allowed inside a plugin folder: $link"

echo "validate-manifest: $PLUGIN_DIR is a valid plugin"
