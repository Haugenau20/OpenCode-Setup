#!/usr/bin/env bash
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Read disabled.yaml into bash arrays (simple awk — no yaml parser needed
# for a flat list-of-lists schema). Falls back to empty arrays.
#
# Supports every form documented in docs/ADDING_SKILLS.md, mixed freely per
# kind within the same file:
#   kind:                upright multiline list
#     - a
#     - b
#   kind: [a, b]          same-line inline array (with or without a space
#   kind:  [a,b]           before the bracket, with or without spaces after commas)
#   kind: []               same-line inline empty array — yields nothing AND
#                           does not leak into the next kind
#   kind:                 array bracket on its own line right after the key
#     [a, b]
#   (kind absent from the file) — yields nothing
#
# One "key:" line (any word immediately followed by a colon, at any indent)
# both opens the section for a matching kind and closes the section for
# whichever kind was previously open — that single rule is what makes
# same-line-empty kinds not leak into whatever list-form kind follows them,
# and what makes a multi-item dash list keep printing entries instead of
# bailing out after the first one.
disabled_for() {
    local kind="$1"
    [ -f "${DISABLED_FILE}" ] || return 0
    awk -v k="${kind}" '
        function items(s,    v) {
            v = s
            gsub(/[][]/, "", v)
            gsub(/,/, " ", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            return v
        }
        # A key line: optional leading whitespace, a bare word, a colon, and
        # optionally an inline value after it. Dash items ("- foo") and
        # standalone bracket lines ("[a, b]") never match this — they start
        # with "-"/"[", not a word character.
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ {
            key = $0
            sub(/^[[:space:]]*/, "", key)
            sub(/:.*$/, "", key)
            rest = $0
            sub(/^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*/, "", rest)

            found = (key == k) ? 1 : 0
            if (found && rest != "") {
                if (rest ~ /^\[/) {
                    v = items(rest)
                    if (v != "") print v
                }
                found = 0   # same-line value fully answers this key
            }
            next
        }
        found && /^[[:space:]]*\[/ {
            v = items($0)
            if (v != "") print v
            found = 0
            next
        }
        found && /^[[:space:]]*-/ {
            sub(/^[[:space:]]*-[[:space:]]*/, "")
            print
            next
        }
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

# Source a policy file (yaml-shaped, flat k:v schema under an `env:` block) as
# env vars. Values may be quoted ("1", "localhost,...") or bare (true) —
# trim() strips a single layer of surrounding quotes/whitespace either way, so
# both forms export cleanly and a quoted value can no longer clobber a correct
# unquoted one compose set. Extracted from the former inline §7 block (see
# main()) so it is unit-testable; the body is unchanged apart from swapping
# the formerly-hardcoded /etc/opencode/policy.yaml path for the $1 parameter.
apply_policy_env() {
    local file="$1"
    if [ -f "${file}" ]; then
        while IFS=: read -r k v; do
            k="${k##* }"; v="$(trim "${v## }")"
            [ -n "${k}" ] && [ -n "${v}" ] && export "${k}=${v}"
        done < <(awk '/^env:/{flag=1;next} flag && /^[^[:space:]]/{flag=0} flag && /^[[:space:]]+[A-Z_]+:/{sub(/^[[:space:]]+/,""); print}' "${file}")
    fi
}

# Split OPENCODE_EXTRA_INSTRUCTIONS into one path per line, dropping empties.
# It is a generic extension point: a space/comma-separated list of extra
# instruction files (absolute paths) to load as global context — main() appends
# each to opencode.json's `instructions`, which opencode concatenates with the
# AGENTS.md files. The container knows nothing about who sets it or why.
#
# This is the image's whole role in surfacing context that lives outside the
# project root. The launcher's `--also <path>` feature (which bind-mounts extra
# folders at /workspace-extra/<name>, siblings of the repo at /workspace that
# opencode's file tools never discover on their own) uses it to point at a
# breadcrumb the launcher generates and mounts — but nothing here is
# `--also`-specific, so the whole feature stays maintained in the launcher.
#
# Deliberately NOT in manifest.json/.env.example (despite the MAINTAINERS.md
# "every env key the container reads goes in the manifest" rule): this var is
# internal launcher->image plumbing, injected by the launcher's --also compose
# overlay, never something a user sets by hand. Listing it would only surface a
# never-touched knob in every .env and make the launcher's manifest drift check
# demand it in the launcher's .env.example too. The manifest exists to catch
# USER-supplied keys an old launcher wouldn't know to prompt for; a
# launcher-injected var can't drift that way, so it stays off the manifest on
# purpose. Do not re-add it.
#
# Mirrors ENABLED_PLUGINS' tolerant comma/space parsing. Prints nothing (loop
# body runs zero times) when the var is unset, so it is a guaranteed no-op on
# the common path. A param-taking helper, like apply_policy_env, so it is
# unit-testable.
extra_instruction_paths() {
    local raw="${1:-}"
    raw="${raw//,/ }"
    local p was_noglob=0
    # noglob for the same reason as extra_allowed_dirs below: split on IFS only,
    # never filename-expand, so a path containing a glob char passes through
    # literally. (Today's inputs are plain file paths, but the sibling hook made
    # this footgun concrete — keep both split idioms identical and safe.)
    case $- in *f*) was_noglob=1 ;; esac
    set -f
    for p in ${raw}; do
        [ -n "${p}" ] && printf '%s\n' "${p}"
    done
    [ "${was_noglob}" = 1 ] || set +f
}

# Split OPENCODE_EXTRA_ALLOWED_DIRS into one glob per line, dropping empties.
# The sibling of extra_instruction_paths for the *access* half of the same
# out-of-project story: a space/comma-separated list of path globs that main()
# folds into opencode.json's `permission.external_directory` as "allow". opencode
# gates any tool touching a path outside the /workspace project root behind that
# permission, which defaults to "ask" — so without this the agent is prompted on
# every read/edit under the launcher's --also mounts (/workspace-extra/<name>),
# defeating the whole point of surfacing them via OPENCODE_EXTRA_INSTRUCTIONS.
# Same contract as that var in every respect: generic, launcher-injected, and
# deliberately kept off manifest.json/.env.example (see that helper's note) —
# the image never learns the launcher's /workspace-extra layout, it just allows
# whatever globs it is handed. Guaranteed no-op when unset. Do not add it to the
# manifest.
extra_allowed_dirs() {
    local raw="${1:-}"
    raw="${raw//,/ }"
    local p was_noglob=0
    # These entries are glob PATTERNS (e.g. /workspace-extra/**), and the --also
    # mounts they name already exist when the entrypoint runs (compose bind-mounts
    # them before PID 1). So an unguarded `for p in ${raw}` would *filename-expand*
    # each pattern against the real filesystem — /workspace-extra/** collapses to
    # the literal leaf dirs (/workspace-extra/demo …), dropping the trailing
    # wildcard opencode needs to match files underneath, and the permission never
    # covers them. Disable globbing so the split is word-splitting ONLY; the
    # pattern reaches jq verbatim. Restore the prior noglob state so the helper
    # has no side effect on its caller.
    case $- in *f*) was_noglob=1 ;; esac
    set -f
    for p in ${raw}; do
        [ -n "${p}" ] && printf '%s\n' "${p}"
    done
    [ "${was_noglob}" = 1 ] || set +f
}

main() {
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

for kind in agents skills commands mcp; do
    symlink_bundle "${kind}"
done

# Global house-rules file. OpenCode reads ~/.config/opencode/AGENTS.md as
# global instructions, concatenated with (not overriding) any project- or
# user-level AGENTS.md. We symlink the bundle copy into the config dir root,
# but never clobber a real file the developer has put there themselves — that
# is their override, same shadow rule as the bundle kinds above.
if [ -f "${BUNDLE}/AGENTS.md" ]; then
    dst="${USER_CFG}/AGENTS.md"
    [ -L "${dst}" ] && [ ! -e "${dst}" ] && rm -f "${dst}"   # drop stale link
    if [ -e "${dst}" ] && [ ! -L "${dst}" ]; then
        log "skip shadowed:  AGENTS.md"
    else
        ln -sfn "${BUNDLE}/AGENTS.md" "${dst}"
    fi
fi

# ---- 3b. Plugins: opt-in, enabled ONLY via the ENABLED_PLUGINS env var --------
# OpenCode auto-scans `{plugin,plugins}/*.{ts,js}` in each config dir and imports
# the files directly (no Bun install, follows symlinks). Each baked plugin lives
# at ${BUNDLE}/plugins/<name>/ with an `entries` manifest
# (`<symlink-name>=<relative/entry/path>` per line); we symlink the entry files
# of the enabled plugins into ${USER_CFG}/plugin/.
#
# ENABLED_PLUGINS (set in .env on the host) is the SINGLE source of truth — a
# space- or comma-separated list, e.g. `ENABLED_PLUGINS=superpowers dcp`. We
# deliberately do NOT read plugin state from disabled.yaml: that file is seeded
# into a persistent volume and would silently override .env (a real footgun).
# The `plugin` array in opencode.json is likewise unused — it triggers a network
# Bun install the egress blocks.
PLUGIN_SRC="${BUNDLE}/plugins"
PLUGIN_DST="${USER_CFG}/plugin"
if [ -d "${PLUGIN_SRC}" ]; then
    # Rebuild the enabled set from scratch each boot so ENABLED_PLUGINS is truly
    # authoritative. Remove every symlink WE manage (target under the bundle),
    # valid or broken — the config dir is a persistent volume, so a link from a
    # previous boot would otherwise linger and keep a plugin on. User-provided
    # real files / symlinks pointing outside the bundle are left untouched.
    if [ -d "${PLUGIN_DST}" ]; then
        for link in "${PLUGIN_DST}"/*; do
            [ -L "${link}" ] || continue
            case "$(readlink "${link}")" in
                "${PLUGIN_SRC}"/*) rm -f "${link}" ;;
            esac
        done
    fi

    # Parse ENABLED_PLUGINS: tolerate commas and stray quotes leaked from .env.
    enabled="${ENABLED_PLUGINS:-}"
    enabled="${enabled//,/ }"
    enabled="${enabled//\"/}"
    enabled="${enabled//\'/}"

    for dir in "${PLUGIN_SRC}"/*/; do
        [ -d "${dir}" ] || continue
        name="$(basename "${dir}")"
        if ! printf ' %s ' "${enabled}" | grep -q " ${name} "; then
            log "plugin off: ${name} (enable via ENABLED_PLUGINS in .env; see /plugins)"
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

SECRETS_DIR=/home/dev/secrets
mkdir -p "${SECRETS_DIR}"
printf '%s' "$(trim "${LLM_API_BASE}")" > "${SECRETS_DIR}/llm_api_base"
printf '%s' "$(trim "${LLM_API_KEY}")"  > "${SECRETS_DIR}/llm_api_key"
chmod 600 "${SECRETS_DIR}/llm_api_base" "${SECRETS_DIR}/llm_api_key"
chown -R "${HOST_UID}:${HOST_GID}" "${SECRETS_DIR}"

# ---- 4b. MCP servers: enabled by credential presence -------------------------
# Each service's MCP is wired into opencode.json ONLY when its credentials are
# set (and it is not explicitly disabled). The servers exit on boot without
# their env, so omitting the block entirely is what keeps an unconfigured
# service quiet instead of noisily failing to attach.
#
# The servers read their config (BITBUCKET_*/JIRA_*, HTTP(S)_PROXY) straight
# from the environment and derive HTTP Basic themselves. Those come from the
# .env env_file and so live in the container's stored env — inherited by any
# process that spawns the server (the backend OR the TUI's docker exec). We do
# NOT export derived vars here: a runtime export only lives in PID 1 and would
# be missing if the TUI process is the one that launches the server.
MCP_DIR=/opt/opencode/mcp-servers
# cfg_filter/cfg_jq_args accumulate the jq that turns the shipped opencode.json
# template into the final generated config: the enabled MCP blocks below, then
# the workspace-extra breadcrumb in §4c. They start as a no-op passthrough.
cfg_filter='.'
cfg_jq_args=()

# One row per service: "<name>:<needs_user>". needs_user=1 means the service
# is also a git remote and authenticates HTTP Basic, so it additionally
# requires <SVC>_USER (Bitbucket, GitLab); needs_user=0 means it's API-only —
# no git transport, PAT presented as a Bearer token, no username involved
# (Jira, JFrog, Confluence). Every service still gates on <SVC>_BASE_URL +
# <SVC>_PAT + DISABLE_<SVC>_MCP != 1. Adding service #6 is: drop the server
# dir under mcp-servers/, add its squid allowlist conf, add one row here, add
# its keys to .env.example AND opencode/manifest.json (see MAINTAINERS.md).
MCP_SERVICES="bitbucket:1 jira:0 gitlab:1 jfrog:0 confluence:0"

for entry in ${MCP_SERVICES}; do
    svc="${entry%%:*}"
    needs_user="${entry#*:}"
    SVC="${svc^^}"

    base_var="${SVC}_BASE_URL";     base="${!base_var:-}"
    pat_var="${SVC}_PAT";           pat="${!pat_var:-}"
    disable_var="DISABLE_${SVC}_MCP"; disable="${!disable_var:-0}"

    # hint mirrors the old hand-written "set X/Y/Z to enable" messages, e.g.
    # "BITBUCKET_BASE_URL/USER/PAT" vs. "JIRA_BASE_URL/PAT".
    user_ok=1
    hint="${SVC}_BASE_URL"
    if [ "${needs_user}" = "1" ]; then
        user_var="${SVC}_USER"; user="${!user_var:-}"
        [ -n "${user}" ] || user_ok=0
        hint="${hint}/USER"
    fi
    hint="${hint}/PAT"

    if [ -n "${base}" ] && [ "${user_ok}" = "1" ] && [ -n "${pat}" ] \
       && [ "${disable}" != "1" ]; then
        arg_name="p_${svc}"
        cfg_filter="${cfg_filter} | .mcp.${svc} = {\"type\":\"local\",\"command\":[\"node\",\$${arg_name}],\"enabled\":true}"
        cfg_jq_args+=(--arg "${arg_name}" "${MCP_DIR}/${svc}/index.js")
        log "mcp on:  ${svc} (${base})"
    else
        log "mcp off: ${svc} (set ${hint} to enable)"
    fi
done

# ---- 4c. Extra instruction files (generic hook) ------------------------------
# Append any paths in OPENCODE_EXTRA_INSTRUCTIONS to opencode.json's
# `instructions` (see extra_instruction_paths above). Each must be an ABSOLUTE
# path: a bare relative instructions entry resolves against the project root
# (/workspace), not here. Guaranteed no-op when the var is unset. The launcher
# sets it (in its --also overlay) to a breadcrumb it generates and mounts,
# keeping that whole feature on its side; the container just loads what it is
# told to.
xi_n=0
while IFS= read -r xi; do
    [ -n "${xi}" ] || continue
    cfg_filter="${cfg_filter} | .instructions = ((.instructions // []) + [\$xi_${xi_n}])"
    cfg_jq_args+=(--arg "xi_${xi_n}" "${xi}")
    xi_n=$((xi_n + 1))
    log "extra instructions: + ${xi}"
done < <(extra_instruction_paths "${OPENCODE_EXTRA_INSTRUCTIONS:-}")

# ---- 4d. Extra allowed directories (generic hook) ----------------------------
# Fold any globs in OPENCODE_EXTRA_ALLOWED_DIRS into opencode.json's
# `permission.external_directory` as "allow" (see extra_allowed_dirs above).
# external_directory defaults to "ask", so without this opencode prompts on
# every access to a path outside /workspace — including the --also mounts the
# breadcrumb from §4c just told the agent to read. Only the listed globs are
# allowed; anything else still hits the "ask" default (no "*" rule is added).
# Guaranteed no-op when the var is unset; the launcher sets it (in its --also
# overlay) to the mount root it owns, keeping the path convention on its side.
xa_n=0
while IFS= read -r xa; do
    [ -n "${xa}" ] || continue
    cfg_filter="${cfg_filter} | .permission.external_directory[\$xa_${xa_n}] = \"allow\""
    cfg_jq_args+=(--arg "xa_${xa_n}" "${xa}")
    xa_n=$((xa_n + 1))
    log "extra allowed dir: + ${xa}"
done < <(extra_allowed_dirs "${OPENCODE_EXTRA_ALLOWED_DIRS:-}")

# Ship the config into the global config dir (alongside bundle symlinks),
# injecting the enabled MCP blocks, any extra instruction files, and any extra
# allowed directories, and pin it so opencode loads exactly this file. With
# nothing enabled the filter is a no-op passthrough.
jq "${cfg_filter}" "${cfg_jq_args[@]}" /etc/opencode/opencode.json \
    > "${USER_CFG}/opencode.json"
export OPENCODE_CONFIG="${USER_CFG}/opencode.json"

# ---- 5. Session state ownership -----------------------------------------------
STATE_DIR=/home/dev/.local/share/opencode
chown -R "${HOST_UID}:${HOST_GID}" "${STATE_DIR}" "${USER_CFG}"

# ---- 6. Git credential helper: host-aware dispatch for multi-host creds ------
# Bitbucket and GitLab each hand out their own PAT, and both can be configured
# at once. A single unconditional helper (the old behavior) would echo ONE
# service's creds for every host — e.g. leaking Bitbucket creds to a GitLab
# remote. Instead we generate a helper function that reads git's credential
# request from stdin, pulls out the `host=` line, strips any `:port` suffix,
# and matches the bare hostname against each configured service so the right
# username/token pair goes to the right remote (multi-host credential
# isolation). Bare-hostname matching is robust even when git includes a port
# in the request.
#
# Derive bare hostnames from the base URLs: strip the scheme (`proto://`),
# any path, and any `:port`.
bb_host="${BITBUCKET_BASE_URL:-}"; bb_host="${bb_host#*://}"; bb_host="${bb_host%%/*}"; bb_host="${bb_host%%:*}"
gl_host="${GITLAB_BASE_URL:-}";    gl_host="${gl_host#*://}";    gl_host="${gl_host%%/*}";    gl_host="${gl_host%%:*}"

if { [ -n "${BITBUCKET_USER:-}" ] && [ -n "${BITBUCKET_PAT:-}" ]; } \
   || { [ -n "${GITLAB_USER:-}" ] && [ -n "${GITLAB_PAT:-}" ]; }; then

    # Build the `case` arms for only the services that are actually configured.
    # git config values cannot span physical lines (without a trailing `\`
    # continuation), so the whole helper function must end up as ONE line in
    # the written .gitconfig — arms are joined with `;` rather than newlines.
    #
    # NOTE: this is shell building shell — `cred_arms` is itself a fragment of
    # the `!f() { ... }; f` function that ends up literally inside the written
    # .gitconfig. Below, `\$host` / `\${host%%:*}` / etc. are escaped (leading
    # backslash) so they stay literal $-expansions in the GENERATED helper
    # (evaluated later, when git invokes it) — while ${bb_host} / ${BITBUCKET_USER}
    # / etc. (no backslash) expand NOW, at generation time, baking the real
    # hostnames/creds into the file.
    cred_arms=""
    if [ -n "${BITBUCKET_USER:-}" ] && [ -n "${BITBUCKET_PAT:-}" ]; then
        cred_arms="${cred_arms}${bb_host}) echo username=${BITBUCKET_USER}; echo password=\${BITBUCKET_PAT} ;; "
    fi
    if [ -n "${GITLAB_USER:-}" ] && [ -n "${GITLAB_PAT:-}" ]; then
        cred_arms="${cred_arms}${gl_host}) echo username=${GITLAB_USER}; echo password=\${GITLAB_PAT} ;; "
    fi

    # Default [user] identity: prefer the explicit GIT_USER_NAME/EMAIL, else
    # fall back to whichever service is configured (Bitbucket first, to match
    # prior behavior when both are set).
    default_user="${BITBUCKET_USER:-${GITLAB_USER:-dev}}"

    cat > /home/dev/.gitconfig <<EOF
[user]
    name = ${GIT_USER_NAME:-${default_user}}
    email = ${GIT_USER_EMAIL:-${default_user}@localhost}
[credential]
    helper = "!f() { host=\$(sed -n 's/^host=//p' | head -n1); host=\${host%%:*}; case \"\$host\" in ${cred_arms}*) ;; esac; }; f"
[safe]
    directory = /workspace
EOF
    chown "${HOST_UID}:${HOST_GID}" /home/dev/.gitconfig
fi

# ---- 7. Apply workplace policy (telemetry kill, etc.) ------------------------
# Source policy.yaml as env vars via apply_policy_env() (defined above), which
# strips a single layer of surrounding quotes/whitespace either way, so both
# quoted and bare forms export cleanly and a quoted NO_PROXY can no longer
# clobber the correct unquoted one compose set.
apply_policy_env /etc/opencode/policy.yaml

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
}

# Run main only when executed directly, not when sourced (e.g. by tests).
# PID-1-critical: this script is the image's ENTRYPOINT. This wrap is a pure
# code-motion refactor (see the commit that introduced it for the
# git diff --color-moved verification) — no logic, ordering, or quoting
# changed. A live `docker build` + boot smoke test is required before this
# ships in a release image; see MAINTAINERS.md.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
