#!/usr/bin/env bash
# nd-plugin-update: update Navidrome plugins within their major version; run as ExecStartPre of the Navidrome service.
# Settings: NPU_* environment variables (see README / nd-plugin-update.env.example). Never blocks startup.
# Usage: nd-plugin-update.sh [--dry-run]

set -uo pipefail

log() { echo "nd-plugin-update: $*"; }

if [[ -z "${NPU_DATA_DIR:-}" ]]; then
    log "NPU_DATA_DIR is not set, nothing to do (see nd-plugin-update.env.example)"
    exit 0
fi
DATA_DIR="$NPU_DATA_DIR"
PLUGINS_DIR="${NPU_PLUGINS_DIR:-$DATA_DIR/plugins}"
BACKUP_DIR="${NPU_BACKUP_DIR:-$DATA_DIR/plugin-backups}"
KEEP_BACKUPS="${NPU_KEEP_BACKUPS:-3}"
IMAGE="${NPU_IMAGE:-docker.io/deluan/navidrome:latest}"
ALLOW="${NPU_PLUGINS:-*}"
EXCLUDE="${NPU_EXCLUDE:-}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ ! -d "$PLUGINS_DIR" ]]; then
    log "plugins folder $PLUGINS_DIR not found, nothing to do"
    exit 0
fi

# true if $1 is in the comma-separated list $2 ("*" matches everything)
in_list() {
    local item
    IFS=',' read -ra items <<<"$2"
    for item in "${items[@]}"; do
        item="${item// /}"
        [[ "$item" == "*" || "$item" == "$1" ]] && return 0
    done
    return 1
}

# "8.1.0" -> "8 1 0"; anything that isn't plain x.y.z (e.g. -rc.1) is rejected
semver() { [[ "$1" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] && echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"; }

# true if $1 > $2 (both x.y.z)
newer() {
    local a b
    read -ra a <<<"$(semver "$1")"; read -ra b <<<"$(semver "$2")"
    for i in 0 1 2; do
        (( a[i] > b[i] )) && return 0
        (( a[i] < b[i] )) && return 1
    done
    return 1
}

manifest() { unzip -p "$1" manifest.json 2>/dev/null; }

nd_cli() {
    podman run --rm --network none --entrypoint /app/navidrome \
        -v "$DATA_DIR:/data:z" -e ND_PLUGINS_ENABLED=true \
        "$IMAGE" --nobanner "$@"
}

shopt -s nullglob
updated=()

for ndp in "$PLUGINS_DIR"/*.ndp; do
    file=$(basename "$ndp")
    id="${file%.ndp}"

    install=1
    if in_list "$id" "$EXCLUDE"; then
        install=0
    elif ! in_list "$id" "$ALLOW"; then
        log "$id: not in NPU_PLUGINS, skipping"
        continue
    fi

    m=$(manifest "$ndp") || { log "$file: can't read manifest, skipping"; continue; }
    cur=$(jq -r '.version // empty' <<<"$m")
    site=$(jq -r '.website // empty' <<<"$m")

    if [[ -z "$(semver "$cur")" ]]; then log "$id: version '$cur' isn't x.y.z, skipping"; continue; fi
    if [[ ! "$site" =~ github\.com/([^/]+)/([^/#?]+) ]]; then log "$id: no GitHub website in manifest, skipping"; continue; fi
    repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    major="${cur%%.*}"

    releases=$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$repo/releases?per_page=50") \
        || { log "$id: GitHub unreachable or rate-limited, skipping"; continue; }

    best="" best_url="" best_digest="" latest_major_ver=""
    while IFS=$'\t' read -r tag url digest; do
        ver="${tag#v}"
        [[ -z "$(semver "$ver")" ]] && continue
        if [[ "${ver%%.*}" == "$major" ]]; then
            if newer "$ver" "${best:-$cur}"; then best="$ver" best_url="$url" best_digest="$digest"; fi
        elif (( ${ver%%.*} > major )); then
            if [[ -z "$latest_major_ver" ]] || newer "$ver" "$latest_major_ver"; then latest_major_ver="$ver"; fi
        fi
    done < <(jq -r --arg f "$file" '.[] | select(.draft|not) | select(.prerelease|not)
        | (.assets | map(select(.name == $f)) + map(select(.name | endswith(".ndp"))))[0] as $a
        | select($a) | [.tag_name, $a.browser_download_url, ($a.digest // "")] | @tsv' <<<"$releases")

    [[ -n "$latest_major_ver" ]] && log "$id: NEW MAJOR VERSION $latest_major_ver available (installed $cur) — update manually, settings may have changed: https://github.com/$repo/releases"

    if [[ -z "$best" ]]; then log "$id: $cur is the newest $major.x"; continue; fi
    if (( ! install )); then log "$id: $best available (installed $cur), not installing: in NPU_EXCLUDE"; continue; fi
    log "$id: updating $cur -> $best"
    (( DRY_RUN )) && continue

    tmp=$(mktemp "$PLUGINS_DIR/.${id}.XXXXXX")
    if ! curl -fsSL --max-time 120 -o "$tmp" "$best_url"; then log "$id: download failed"; rm -f "$tmp"; continue; fi
    if [[ "$best_digest" == sha256:* ]] && [[ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "${best_digest#sha256:}" ]]; then
        log "$id: checksum mismatch, NOT installing"; rm -f "$tmp"; continue
    fi
    newm=$(manifest "$tmp")
    if [[ "$(jq -r .version <<<"$newm")" != "$best" || "$(jq -r .name <<<"$newm")" != "$(jq -r .name <<<"$m")" ]]; then
        log "$id: downloaded file's manifest doesn't match release $best, NOT installing"; rm -f "$tmp"; continue
    fi

    mkdir -p "$BACKUP_DIR"
    cp -p "$ndp" "$BACKUP_DIR/$id-$cur.ndp"
    ls -1t "$BACKUP_DIR/$id"-*.ndp 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
    chmod 644 "$tmp"
    mv -f "$tmp" "$ndp"
    updated+=("$id")
    log "$id: installed $best (old version saved to $BACKUP_DIR/$id-$cur.ndp)"
done

# Re-enable updated plugins: the CLI rescans (records the new file) then enables.
if (( ${#updated[@]} )); then
    if nd_cli plugin rescan >/dev/null 2>&1; then
        for id in "${updated[@]}"; do
            if nd_cli plugin enable "$id" >/dev/null 2>&1; then
                log "$id: re-enabled"
            else
                log "$id: could NOT re-enable (config may need review in Settings -> Plugins)"
            fi
        done
    else
        log "plugin rescan failed; enable updated plugins manually: ${updated[*]}"
    fi
fi

exit 0
