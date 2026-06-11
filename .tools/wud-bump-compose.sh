#!/bin/bash
#
# wud-bump-compose.sh — bump image tags in docker-compose files to the versions
#                       WUD reports as available.
#
# WUD only DETECTS updates; it never edits files or redeploys. This script reads
# WUD's REST API and rewrites the `image:` tag in the exact compose file WUD
# associates with each container (via its com.docker.compose.* labels).
#
# It applies whatever tag WUD recommends (result.tag). If WUD surfaces noisy tags
# (rc / dev / -ubuntu / -windows variants, ...), constrain them at the source with
# per-container WUD labels — e.g.  wud.tag.exclude=dev|rc|alpha|beta  — instead of
# filtering here. That keeps a single source of truth (WUD) for what "newer" means.
#
# A tag is only rewritten when the container's CURRENT tag (what WUD sees running)
# actually exists in the compose file. If they differ (e.g. the file was already
# edited but not redeployed), that container is reported and skipped — never guessed.
#
# Usage:
#   ./wud-bump-compose.sh              # preview, then ask before writing
#   ./wud-bump-compose.sh --dry-run    # preview only, never write
#   ./wud-bump-compose.sh --yes        # apply without prompting
#
# Env:
#   WUD_URL   Base URL of the WUD API. Default: auto-detected from the `wud`
#             container's IP on its Docker network, port 3000.

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    -h|--help)    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

command -v jq   >/dev/null || { echo "❌ 'jq' is required."   >&2; exit 1; }
command -v perl >/dev/null || { echo "❌ 'perl' is required." >&2; exit 1; }

# Show compose paths relative to the repo root when possible (purely cosmetic).
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || echo /home/greenserver/apps)"
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

# --- Resolve the WUD API endpoint -----------------------------------------
WUD_URL="${WUD_URL:-}"
if [ -z "$WUD_URL" ]; then
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' wud 2>/dev/null | awk '{print $1}')"
  [ -n "$ip" ] || { echo "❌ Can't find the 'wud' container. Set WUD_URL=http://host:3000" >&2; exit 1; }
  WUD_URL="http://${ip}:3000"
fi

echo "🔎 Querying WUD at ${WUD_URL} ..."
containers="$(curl -fsS --max-time 10 "${WUD_URL}/api/containers")" \
  || { echo "❌ Failed to reach the WUD API at ${WUD_URL}" >&2; exit 1; }

# --- Collect tag updates ---------------------------------------------------
# tsv columns: name, imageName, oldTag, newTag, service, configFiles
updates="$(printf '%s' "$containers" | jq -r '
  .[]
  | select(.updateAvailable == true)
  | select(.updateKind.kind == "tag")                       # digest-only updates have no tag to bump
  | select(.result.tag != null and .result.tag != .updateKind.localValue)
  | [ .name,
      .image.name,
      .updateKind.localValue,
      .result.tag,
      (.labels["com.docker.compose.service"] // .name),
      (.labels["com.docker.compose.project.config_files"] // "")
    ] | @tsv')"

if [ -z "$updates" ]; then
  echo "✅ No tag updates reported by WUD."
  exit 0
fi

# --- Build the plan --------------------------------------------------------
# PLAN rows (apply):  file \t service \t base \t old \t new \t name
# Anything we can't safely locate goes to WARN instead.
PLAN=""
WARN=""
while IFS=$'\t' read -r name image old new service files; do
  [ -n "$name" ] || continue
  base="${image##*/}"                       # last path segment, e.g. library/eclipse-mosquitto -> eclipse-mosquitto

  target=""
  IFS=',' read -ra flist <<< "$files"
  for f in "${flist[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"   # trim
    if [ -n "$f" ] && [ -f "$f" ] && grep -qF "${base}:${old}" "$f"; then
      target="$f"; break
    fi
  done

  if [ -n "$target" ]; then
    PLAN+="${target}"$'\t'"${service}"$'\t'"${base}"$'\t'"${old}"$'\t'"${new}"$'\t'"${name}"$'\n'
  else
    WARN+="${name}"$'\t'"${base}:${old}"$'\t'"${files}"$'\n'
  fi
done <<< "$updates"

# --- Preview ---------------------------------------------------------------
echo
echo "📦 Updates available:"
printf '   %-22s %-34s %s\n' "CONTAINER" "FILE" "CHANGE"
if [ -n "$PLAN" ]; then
  while IFS=$'\t' read -r file service base old new name; do
    [ -n "$name" ] || continue
    printf '   %-22s %-34s %s\n' "$name" "$(rel "$file")" "${base}:${old}  →  ${base}:${new}"
  done <<< "$PLAN"
fi
if [ -n "$WARN" ]; then
  echo
  echo "⚠️  Skipped (current tag not found in compose — running container may be out of sync):"
  while IFS=$'\t' read -r name ref files; do
    [ -n "$name" ] || continue
    printf '   %-22s looked for %-26s in %s\n' "$name" "$ref" "$(rel "${files%%,*}")"
  done <<< "$WARN"
fi

[ -n "$PLAN" ] || { echo; echo "Nothing to apply."; exit 0; }

count="$(printf '%s' "$PLAN" | grep -c .)"

# --- Confirm / apply -------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "🧪 --dry-run: no files changed."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  echo
  read -r -p "Apply these ${count} update(s) to the compose files? [y/N] " reply
  case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 0 ;; esac
fi

echo
applied=""
while IFS=$'\t' read -r file service base old new name; do
  [ -n "$name" ] || continue
  OLDREF="${base}:${old}" NEWREF="${base}:${new}" perl -i -pe '
    BEGIN { $o = quotemeta($ENV{OLDREF}); $n = $ENV{NEWREF}; }
    s/(?<![A-Za-z0-9_.\-])$o(?=["\x27\s#]|$)/$n/g;
  ' "$file"

  if grep -qF "${base}:${new}" "$file"; then
    echo "   ✅ ${name}: ${base}:${old} → ${base}:${new}  ($(rel "$file"))"
    applied+="${file}"$'\t'"${service}"$'\n'
  else
    echo "   ❌ ${name}: replacement did not take in $(rel "$file") — check manually" >&2
  fi
done <<< "$PLAN"

# --- Next steps ------------------------------------------------------------
if [ -n "$applied" ]; then
  echo
  echo "🚀 To pull and redeploy the updated services:"
  while IFS=$'\t' read -r file service; do
    [ -n "$file" ] || continue
    echo "   docker compose -f \"$file\" pull $service && docker compose -f \"$file\" up -d $service"
  done <<< "$applied"
  echo
  echo "Review first with:  git -C \"$ROOT\" diff -- '*docker-compose*'"
fi
