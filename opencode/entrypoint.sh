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

mkdir -p "${USER_CFG}"/{agents,skills,commands,mcp}

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

# ---- 4. Render opencode.json from template -----------------------------------
: "${LLM_API_BASE:?LLM_API_BASE not set}"
: "${LLM_API_KEY:?LLM_API_KEY not set}"

envsubst < /etc/opencode/opencode.json.tmpl > "${USER_CFG}/opencode.json"

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
log "starting opencode: $*"
exec gosu dev opencode "$@" \
    --hostname 0.0.0.0 \
    --port "${OPENCODE_INTERNAL_PORT:-4096}"
