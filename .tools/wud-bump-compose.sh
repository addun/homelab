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
#   ./wud-bump-compose.sh              # preview, then pick which updates to apply
#                                      #   checkbox list (whiptail) in a terminal; otherwise
#                                      #   a prompt: "1,3", "2-4", "a" = all, Enter = none
#   ./wud-bump-compose.sh --dry-run    # preview only, never write
#   ./wud-bump-compose.sh --yes        # apply all without prompting
#
# Env:
#   WUD_URL   Base URL of the WUD API. Default: auto-detected from the `wud`
#             container's IP on its Docker network, port 3000.
#   WUD_USER / WUD_PASS   Basic-auth credentials. Default: WUD_ADMIN_USER /
#             WUD_ADMIN_PASSWORD from ops/.env.

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    -h|--help)    sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# WUD >= 9 requires auth; default to the admin credentials from ops/.env.
ENV_FILE="$ROOT/ops/.env"
envval() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }
WUD_USER="${WUD_USER:-$(envval WUD_ADMIN_USER)}"
WUD_PASS="${WUD_PASS:-$(envval WUD_ADMIN_PASSWORD)}"
CURL_AUTH=()
[ -n "$WUD_USER" ] && CURL_AUTH=(-u "${WUD_USER}:${WUD_PASS}")

echo "🔎 Querying WUD at ${WUD_URL} ..."
containers="$(curl -fsS --max-time 10 "${CURL_AUTH[@]}" "${WUD_URL}/api/containers")" \
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
printf '   %3s  %-22s %-34s %s\n' "#" "CONTAINER" "FILE" "CHANGE"
if [ -n "$PLAN" ]; then
  i=0
  while IFS=$'\t' read -r file service base old new name; do
    [ -n "$name" ] || continue
    i=$((i + 1))
    printf '   %3d  %-22s %-34s %s\n' "$i" "$name" "$(rel "$file")" "${base}:${old}  →  ${base}:${new}"
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
  reply=""
  if command -v whiptail >/dev/null && [ -t 0 ] && [ -t 1 ]; then
    # Checkbox UI: SPACE toggles, A-Z jumps, ENTER confirms, ESC cancels.
    items=()
    i=0
    while IFS=$'\t' read -r file service base old new name; do
      [ -n "$name" ] || continue
      i=$((i + 1))
      items+=("$i" "${name}  ${base}:${old} → ${new}" OFF)
    done <<< "$PLAN"
    # Calm dark theme instead of whiptail's default magenta; override with your own NEWT_COLORS.
    export NEWT_COLORS="${NEWT_COLORS:-root=,black window=white,black border=white,black shadow=,black title=white,black roottext=white,black helpline=white,black label=white,black textbox=white,black acttextbox=white,black button=black,white actbutton=white,blue checkbox=white,black actcheckbox=black,cyan listbox=white,black actlistbox=white,blue sellistbox=cyan,black actsellistbox=white,blue}"
    rows="$(tput lines 2>/dev/null || echo 24)"
    cols="$(tput cols 2>/dev/null || echo 80)"
    h=$((rows - 4)); w=$((cols - 6))
    picked="$(whiptail --title "WUD updates" --separate-output --checklist \
      "SPACE = toggle, ENTER = apply selected, ESC = cancel" \
      "$h" "$w" $((h - 8)) "${items[@]}" 3>&1 1>&2 2>&3)" || { echo "Aborted."; exit 0; }
    [ -n "$picked" ] || { echo "Nothing selected."; exit 0; }
    reply="$(printf '%s' "$picked" | paste -sd, -)"
  else
    read -r -p "Which update(s) to apply? [numbers e.g. 1,3 or 2-4 | a=all | N=none]: " reply
  fi
  reply="${reply// /}"
  case "$reply" in
    a|A|all|ALL) ;;
    ""|n|N|none) echo "Aborted."; exit 0 ;;
    *)
      selected=","
      IFS=',' read -ra parts <<< "$reply"
      for p in "${parts[@]}"; do
        if [[ "$p" =~ ^[0-9]+$ ]]; then
          from="$p"; to="$p"
        elif [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          from="${BASH_REMATCH[1]}"; to="${BASH_REMATCH[2]}"
        else
          echo "❌ Invalid selection: '$p'" >&2; exit 2
        fi
        if [ "$from" -lt 1 ] || [ "$to" -gt "$count" ] || [ "$from" -gt "$to" ]; then
          echo "❌ Selection '$p' out of range (1-${count})" >&2; exit 2
        fi
        for ((n = from; n <= to; n++)); do selected+="${n},"; done
      done

      filtered=""
      i=0
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        i=$((i + 1))
        case "$selected" in *",${i},"*) filtered+="${row}"$'\n' ;; esac
      done <<< "$PLAN"
      PLAN="$filtered"
      ;;
  esac
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
    echo "   docker compose -f \"$file\" up -d --pull always $service"
  done <<< "$applied"
  echo
  echo "Review first with:  git -C \"$ROOT\" diff -- '*docker-compose*'"
fi
