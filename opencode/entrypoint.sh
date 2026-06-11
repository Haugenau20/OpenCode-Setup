#!/usr/bin/env bash
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ---- 1. UID/GID remap so bind-mounted files have sane ownership --------------
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

current_uid="$(id -u dev)"
current_gid="$(id -g dev)"

if [ "${current_uid}" != "${HOST_UID}" ] || [ "${current_gid}" != "${HOST_GID}" ]; then
    log "remapping dev to ${HOST_UID}:${HOST_GID} (was ${current_uid}:${current_gid})"
    groupmod -o -g "${HOST_GID}" dev
    usermod  -o -u "${HOST_UID}" dev
    chown -R "${HOST_UID}:${HOST_GID}" /home/dev /workspace
fi

# ---- 2. Refresh CA bundle in case a volume mounted extra certs ---------------
update-ca-certificates >/dev/null 2>&1 || true

# ---- 3. Build the merged config layer in ~/.config/opencode ------------------
USER_CFG=/home/dev/.config/opencode
BUNDLE=/opt/opencode/bundle
DISABLED_FILE="${USER_CFG}/disabled.yaml"

mkdir -p "${USER_CFG}"/{agents,skills,commands,mcp,plugin}

# Seed the developer's on/off switch file on first boot. It is the single
# control surface for toggling bundled content (and the menu the `/plugins`
# command points at). We never overwrite an existing one — it lives in the
# user-config volume and is the developer's to edit.
if [ ! -f "${DISABLED_FILE}" ] && [ -f /etc/opencode/disabled.yaml.default ]; then
    cp /etc/opencode/disabled.yaml.default "${DISABLED_FILE}"
    log "seeded ${DISABLED_FILE} (edit it to toggle bundled content; see /plugins)"
fi

# Read disabled.yaml into bash arrays (simple grep — no yaml parser needed
# for a flat list-of-lists schema). Falls back to empty arrays.
disabled_for() {
    local kind="$1"
    [ -f "${DISABLED_FILE}" ] || return 0
    awk -v k="${kind}" '
        $0 ~ "^[[:space:]]*"k":" {found=1; next}
        found && /^[[:space:]]*\[/ {
            gsub(/[][]/, ""); gsub(/,/, " "); print; exit
        }
        found && /^[[:space:]]*-/ {sub(/^[[:space:]]*-[[:space:]]*/, ""); print}
        found && /^[a-zA-Z]/ {exit}
    ' "${DISABLED_FILE}"
}

symlink_bundle() {
    local kind="$1"
    local src="${BUNDLE}/${kind}"
    local dst="${USER_CFG}/${kind}"
    [ -d "${src}" ] || return 0

    # Drop dangling symlinks left by an earlier image/bundle layout. The config
    # dir is a persistent volume, so stale links survive rebuilds otherwise.
    find "${dst}" -maxdepth 1 -xtype l -delete 2>/dev/null || true

    local disabled
    disabled="$(disabled_for "${kind}" | tr '\n' ' ')"

    for entry in "${src}"/*; do
        [ -e "${entry}" ] || continue
        local name; name="$(basename "${entry}")"
        # Skip if disabled or already shadowed by a user file.
        if printf ' %s ' "${disabled}" | grep -q " ${name%.*} "; then
            log "skip disabled: ${kind}/${name}"
            continue
        fi
        if [ -e "${dst}/${name}" ] && [ ! -L "${dst}/${name}" ]; then
            log "skip shadowed:  ${kind}/${name}"
            continue
        fi
        ln -sfn "${entry}" "${dst}/${name}"
    done
}

for kind in agents skills commands mcp; do
    symlink_bundle "${kind}"
done

# ---- 3b. Plugins: opt-in (default OFF), symlinked into plugin/ ----------------
# OpenCode 1.16.2 auto-scans `{plugin,plugins}/*.{ts,js}` in each config dir and
# imports the files directly (no Bun install, follows symlinks). We exploit that:
# each baked plugin lives at ${BUNDLE}/plugins/<name>/ with an `entries` manifest
# (`<symlink-name>=<relative/entry/path>` per line); we symlink the entry files
# of ENABLED plugins into ${USER_CFG}/plugin/. Plugins are opt-in: a plugin is
# linked only if its <name> appears in the ENABLED_PLUGINS env var (set in .env —
# the easy host-side toggle) OR under `plugins: { enabled: [...] }` in
# disabled.yaml; the two are unioned. The `plugin` array in opencode.json is
# deliberately NOT used — it triggers a network Bun install the egress blocks.

# Names listed under the nested `plugins: -> enabled:` block of disabled.yaml.
enabled_plugins() {
    [ -f "${DISABLED_FILE}" ] || return 0
    awk '
        /^plugins:/ {p=1; next}
        p && /^[a-zA-Z]/ {p=0}                       # left the plugins: block
        p && /^[[:space:]]+enabled:/ {e=1; next}
        p && e && /^[[:space:]]+-/ {
            sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); print
        }
        p && e && /^[[:space:]]+[a-zA-Z]/ {e=0}       # left the enabled: sub-block
    ' "${DISABLED_FILE}"
}

PLUGIN_SRC="${BUNDLE}/plugins"
PLUGIN_DST="${USER_CFG}/plugin"
if [ -d "${PLUGIN_SRC}" ]; then
    # Drop stale plugin symlinks from a previous boot/bundle (config is a volume).
    find "${PLUGIN_DST}" -maxdepth 1 -xtype l -delete 2>/dev/null || true

    # ENABLED_PLUGINS (set in .env on the host) is the low-friction toggle:
    # space- or comma-separated plugin names. We union it with the file-based
    # `plugins.enabled` list so both the easy path and per-developer
    # disabled.yaml edits work. Tolerate commas and stray quotes from .env.
    env_enabled="${ENABLED_PLUGINS:-}"
    env_enabled="${env_enabled//,/ }"
    env_enabled="${env_enabled//\"/}"
    env_enabled="${env_enabled//\'/}"
    enabled="$(enabled_plugins | tr '\n' ' ') ${env_enabled}"
    for dir in "${PLUGIN_SRC}"/*/; do
        [ -d "${dir}" ] || continue
        name="$(basename "${dir}")"
        if ! printf ' %s ' "${enabled}" | grep -q " ${name} "; then
            log "plugin off: ${name} (enable in disabled.yaml; see /plugins)"
            continue
        fi
        [ -f "${dir}entries" ] || { log "plugin ${name}: no entries manifest, skipping"; continue; }
        while IFS='=' read -r linkname relpath; do
            [ -n "${linkname}" ] && [ -n "${relpath}" ] || continue
            case "${linkname}" in \#*) continue ;; esac
            ln -sfn "${dir}${relpath}" "${PLUGIN_DST}/${linkname}"
        done < "${dir}entries"
        # Per-plugin runtime config seeded into the user config dir, if shipped.
        if [ -f "${dir}seed/dcp.jsonc" ] && [ ! -f "${USER_CFG}/dcp.jsonc" ]; then
            cp "${dir}seed/dcp.jsonc" "${USER_CFG}/dcp.jsonc"
        fi
        log "plugin on:  ${name}"
    done
fi

# ---- 4. Provision LLM credentials + config -----------------------------------
# opencode's {env:...} substitution is unreliable for apiKey in custom providers
# (upstream bug), so we write the credentials to root-owned-then-dev 0600 files
# and reference them from opencode.json via {file:...}, which works reliably.
: "${LLM_API_BASE:?LLM_API_BASE not set}"
: "${LLM_API_KEY:?LLM_API_KEY not set}"

# Strip a single layer of surrounding quotes and any surrounding whitespace that
# may have leaked in from .env (docker env_file keeps quotes/spaces literally).
trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"   # leading ws
    v="${v%"${v##*[![:space:]]}"}"   # trailing ws
    v="${v#\"}"; v="${v%\"}"          # surrounding double quotes
    v="${v#\'}"; v="${v%\'}"          # surrounding single quotes
    printf '%s' "$v"
}

SECRETS_DIR=/home/dev/secrets
mkdir -p "${SECRETS_DIR}"
printf '%s' "$(trim "${LLM_API_BASE}")" > "${SECRETS_DIR}/llm_api_base"
printf '%s' "$(trim "${LLM_API_KEY}")"  > "${SECRETS_DIR}/llm_api_key"
chmod 600 "${SECRETS_DIR}/llm_api_base" "${SECRETS_DIR}/llm_api_key"
chown -R "${HOST_UID}:${HOST_GID}" "${SECRETS_DIR}"

# Ship the static config into the global config dir (alongside bundle symlinks)
# and pin it explicitly so opencode loads exactly this file.
cp /etc/opencode/opencode.json "${USER_CFG}/opencode.json"
export OPENCODE_CONFIG="${USER_CFG}/opencode.json"

# ---- 5. Session logs: tmpfs swap if disabled ---------------------------------
STATE_DIR=/home/dev/.local/share/opencode
if [ "${ENABLE_SESSION_LOGS:-1}" != "1" ]; then
    log "session logs disabled; mounting tmpfs over ${STATE_DIR}"
    mount -t tmpfs -o size=256m tmpfs "${STATE_DIR}" 2>/dev/null \
        || log "tmpfs mount failed (no CAP_SYS_ADMIN?); using volume anyway"
fi
chown -R "${HOST_UID}:${HOST_GID}" "${STATE_DIR}" "${USER_CFG}"

# ---- 6. Git credential helper for Bitbucket PAT ------------------------------
if [ -n "${BITBUCKET_USER:-}" ] && [ -n "${BITBUCKET_PAT:-}" ]; then
    cat > /home/dev/.gitconfig <<EOF
[user]
    name = ${GIT_USER_NAME:-${BITBUCKET_USER}}
    email = ${GIT_USER_EMAIL:-${BITBUCKET_USER}@localhost}
[credential]
    helper = "!f() { echo username=${BITBUCKET_USER}; echo password=\${BITBUCKET_PAT}; }; f"
[safe]
    directory = /workspace
EOF
    chown "${HOST_UID}:${HOST_GID}" /home/dev/.gitconfig
fi

# ---- 7. Apply workplace policy (telemetry kill, etc.) ------------------------
# Source policy.yaml as env vars. policy.yaml is yaml-shaped but uses a flat
# k:v schema for the `env:` block, so we grep it out.
if [ -f /etc/opencode/policy.yaml ]; then
    while IFS=: read -r k v; do
        k="${k##* }"; v="${v## }"
        [ -n "${k}" ] && [ -n "${v}" ] && export "${k}=${v}"
    done < <(awk '/^env:/{flag=1;next} flag && /^[^[:space:]]/{flag=0} flag && /^[[:space:]]+[A-Z_]+:/{sub(/^[[:space:]]+/,""); print}' /etc/opencode/policy.yaml)
fi

# ---- 8. Shell prompt reflects git gate ---------------------------------------
PROMPT_GIT_TAG='git:ro'
[ "${ALLOW_REMOTE_GIT:-0}" = "1" ] && PROMPT_GIT_TAG='git:rw'
cat > /home/dev/.bashrc <<EOF
# shipped by opencode-workplace entrypoint
export PS1='\[\e[36m\][oc:${PROJECT_SLUG:-?}|${PROMPT_GIT_TAG}]\[\e[0m\] \w \$ '
export EDITOR=vim
cd /workspace
EOF
chown "${HOST_UID}:${HOST_GID}" /home/dev/.bashrc

# ---- 9. Hand off to opencode -------------------------------------------------
# gosu drops privileges but does NOT reset the environment, so $HOME would stay
# /root (the entrypoint runs as root). opencode resolves its *global config dir*
# (~/.config/opencode, where the bundle is symlinked) from $HOME / $XDG_*, so
# without this the dev process reads root's empty config and no bundled
# agents/skills/commands load — even though OPENCODE_CONFIG pins the provider.
export HOME=/home/dev
export XDG_CONFIG_HOME=/home/dev/.config
export XDG_DATA_HOME=/home/dev/.local/share
log "starting opencode: $*"
exec gosu dev opencode "$@" \
    --hostname 0.0.0.0 \
    --port "${OPENCODE_INTERNAL_PORT:-4096}"
