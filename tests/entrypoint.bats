#!/usr/bin/env bats
#
# Unit tests for the pure helpers in opencode/entrypoint.sh. The file wraps
# its top-level boot flow in main(), guarded by a source-guard at the bottom
# (`[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"`), so sourcing it here never
# runs the PID-1 boot sequence — see the commit that introduced the wrap for
# the git-diff --color-moved verification that it's a pure move.
#
# Every test runs the source + call inside its OWN `bash -c` subshell (never
# directly in the bats test process) because entrypoint.sh keeps
# `set -euo pipefail` at file scope — sourcing it flips those shell options
# for whatever shell does the sourcing, and isolating that to a throwaway
# subshell keeps it from leaking into other tests.

setup() {
  load common
}

# src — a `bash -c` snippet that sources entrypoint.sh with strict-mode's
# `-u` relaxed just for the source itself is NOT needed: entrypoint.sh's own
# functions are set -u safe by construction (they only reference variables
# the test wires up first). Callers append their own commands after this.
SRC='source "$ENTRYPOINT"'

# --- trim() -------------------------------------------------------------

@test "trim: strips leading and trailing whitespace" {
  run bash -c "$SRC"'; trim "  hello  "'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "trim: strips a single layer of surrounding double quotes" {
  run bash -c "$SRC"'; trim "\"hello\""'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "trim: strips a single layer of surrounding single quotes" {
  run bash -c "$SRC"'; trim "'"'"'hello'"'"'"'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "trim: whitespace then quotes — both layers strip (ws outside the quotes)" {
  run bash -c "$SRC"'; trim "  \"hello\"  "'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "trim: whitespace INSIDE the quotes is preserved (ws-strip runs once, before quote-strip)" {
  run bash -c "$SRC"'; trim "\"  hello  \""'
  [ "$status" -eq 0 ]
  [ "$output" = "  hello  " ]
}

@test "trim: a bare value with no quotes or whitespace passes through unchanged" {
  run bash -c "$SRC"'; trim "no quotes here"'
  [ "$status" -eq 0 ]
  [ "$output" = "no quotes here" ]
}

@test "trim: empty string stays empty" {
  run bash -c "$SRC"'; printf "[%s]" "$(trim "")"'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "trim: a pair of double quotes with nothing between them trims to empty" {
  run bash -c "$SRC"'; printf "[%s]" "$(trim "\"\"")"'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "trim: an unbalanced leading quote (no matching close) still strips that one side" {
  # Each quote-strip is independent (leading vs trailing), not a matched-pair
  # check — a value with only an opening quote still loses it.
  run bash -c "$SRC"'; trim "\"value"'
  [ "$status" -eq 0 ]
  [ "$output" = "value" ]
}

@test "trim: nested quotes only unwrap ONE layer (double-quote pass runs before single, so an outer single/inner double is only half-unwrapped)" {
  run bash -c "$SRC"'; trim "'"'"'\"hi\"'"'"'"'
  [ "$status" -eq 0 ]
  [ "$output" = '"hi"' ]
}

@test "trim: a value with embedded colons (NO_PROXY-shaped) is untouched apart from quotes" {
  run bash -c "$SRC"'; trim "\"localhost,127.0.0.1,::1,opencode,rag,squid,.local\""'
  [ "$status" -eq 0 ]
  [ "$output" = "localhost,127.0.0.1,::1,opencode,rag,squid,.local" ]
}

# --- disabled_for() -------------------------------------------------------
# disabled_for() reads the global $DISABLED_FILE (set by main() in the real
# boot flow); tests set it explicitly before sourcing/calling.

@test "disabled_for: missing file returns empty and exit 0 (never errors)" {
  run bash -c 'DISABLED_FILE="/nonexistent/disabled.yaml"; '"$SRC"'; disabled_for agents'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "disabled_for: the shipped disabled.yaml.default (same-line empty arrays) disables nothing for every kind" {
  # This is the exact file the entrypoint seeds on first boot — pin that the
  # all-empty default really does yield an empty disabled set for every kind.
  run bash -c 'DISABLED_FILE="'"$REPO_ROOT"'/opencode/disabled.yaml.default"; '"$SRC"'
    for k in agents skills commands mcp themes; do
      disabled_for "$k"
    done'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "disabled_for: multi-line dash list — every item is returned, not just the first" {
  # Each dash line is printed and the scan moves on to the next line instead
  # of bailing out after the first — a multi-entry list under a kind disables
  # all of them, not just the first.
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents:' \
    '    - code-reviewer' \
    '    - security-review' \
    '  skills:  []' \
    '  commands: []' \
    '  mcp:     []' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for agents'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'code-reviewer\nsecurity-review')" ]
}

@test "disabled_for: the docs/ADDING_SKILLS.md documented same-line inline-array form is honored" {
  # docs/ADDING_SKILLS.md documents:
  #   agents:  [code-reviewer]
  # The key-match rule now inspects whatever follows the colon on the SAME
  # line before moving on, so a same-line inline array is parsed instead of
  # silently discarded.
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents:  [code-reviewer]' \
    '  skills:  [security-review]' \
    '  commands: []' \
    '  mcp:     []' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for agents'
  [ "$status" -eq 0 ]
  [ "$output" = "code-reviewer" ]
}

@test "disabled_for: same-line inline array with multiple items and no space after commas" {
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents: [code-reviewer,security-review]' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for agents'
  [ "$status" -eq 0 ]
  padded=" $(printf '%s' "$output" | tr -s '[:space:]' ' ') "
  [[ "$padded" == *" code-reviewer "* ]]
  [[ "$padded" == *" security-review "* ]]
}

@test "disabled_for: same-line inline array immediately follows the colon (no space before the bracket)" {
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents:[code-reviewer]' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for agents'
  [ "$status" -eq 0 ]
  [ "$output" = "code-reviewer" ]
}

@test "disabled_for: same-line inline empty array yields nothing for that kind" {
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents: []' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for agents'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "disabled_for: an array on its OWN line after the key (one of several supported inline-array forms) IS honored" {
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents:' \
    '  [code-reviewer, security-review]' \
    '  skills:  []' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for agents'
  [ "$status" -eq 0 ]
  # This form emits the whole bracket line as ONE record (gsub only swaps the
  # brackets/commas for spaces, it does not split into one-item-per-line the
  # way the dash-list form does) — but symlink_bundle only ever consumes this
  # through `tr '\n' ' '` + a padded substring grep, so both raw forms end up
  # equivalent by the time a real caller uses them. Assert on that same
  # substance rather than pin the incidental whitespace of the raw line.
  padded=" $(printf '%s' "$output" | tr -s '[:space:]' ' ') "
  [[ "$padded" == *" code-reviewer "* ]]
  [[ "$padded" == *" security-review "* ]]
}

@test "disabled_for: other-kind isolation holds regardless of what forms the neighboring kinds use" {
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents:' \
    '    - code-reviewer' \
    '  skills:  []' \
    '  commands: []' \
    '  mcp:     []' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for skills; disabled_for commands; disabled_for mcp'
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # none of these leak "code-reviewer" from the agents section
}

@test "disabled_for: a same-line-empty kind NOT LAST in the file no longer leaks the next kind's list-form items" {
  # skills is declared "skills:  []" (same line) and is not the last key.
  # Every key line — including the next one, "commands:" — now closes
  # whatever kind was previously open, so the empty skills section can no
  # longer fall through into commands' list and leak "old-release-notes"
  # back out under a "skills" query.
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents:' \
    '    - code-reviewer' \
    '  skills:  []' \
    '  commands:' \
    '    - old-release-notes' \
    '  mcp:     []' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for skills'
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # skills' own (empty) list — nothing from commands: leaks in

  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for commands'
  [ "$status" -eq 0 ]
  [ "$output" = "old-release-notes" ]   # commands' own item is still returned correctly
}

@test "disabled_for: a kind absent from the file entirely yields nothing" {
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents:' \
    '    - code-reviewer' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for skills; disabled_for commands; disabled_for mcp'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "disabled_for: a file mixing every form, one per kind, resolves each kind correctly" {
  local f="$BATS_TEST_TMPDIR/dis.yaml"
  printf '%s\n' \
    'disabled:' \
    '  agents:' \
    '    - code-reviewer' \
    '    - security-review' \
    '  skills:  [old-skill]' \
    '  commands: []' \
    '  mcp:' \
    '    [bitbucket, gitlab]' \
    > "$f"
  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for agents'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'code-reviewer\nsecurity-review')" ]

  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for skills'
  [ "$status" -eq 0 ]
  [ "$output" = "old-skill" ]

  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for commands'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash -c 'DISABLED_FILE="'"$f"'"; '"$SRC"'; disabled_for mcp'
  [ "$status" -eq 0 ]
  padded=" $(printf '%s' "$output" | tr -s '[:space:]' ' ') "
  [[ "$padded" == *" bitbucket "* ]]
  [[ "$padded" == *" gitlab "* ]]
}

# --- apply_policy_env() ---------------------------------------------------

@test "apply_policy_env: a double-quoted value exports without quote characters" {
  local f="$BATS_TEST_TMPDIR/policy.yaml"
  printf '%s\n' 'env:' '  OPENCODE_DISABLE_TELEMETRY: "1"' > "$f"
  run bash -c "$SRC"'; apply_policy_env "'"$f"'"; printf "%s" "$OPENCODE_DISABLE_TELEMETRY"'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [[ "$output" != *'"'* ]]
}

@test "apply_policy_env: a single-quoted value exports without quote characters" {
  local f="$BATS_TEST_TMPDIR/policy.yaml"
  printf "%s\n" 'env:' "  FOO: 'baz'" > "$f"
  run bash -c "$SRC"'; apply_policy_env "'"$f"'"; printf "%s" "$FOO"'
  [ "$status" -eq 0 ]
  [ "$output" = "baz" ]
}

@test "apply_policy_env: an unquoted value exports as-is" {
  local f="$BATS_TEST_TMPDIR/policy.yaml"
  printf '%s\n' 'env:' '  BUN_CONFIG_SKIP_INSTALL_PACKAGES: true' > "$f"
  run bash -c "$SRC"'; apply_policy_env "'"$f"'"; printf "%s" "$BUN_CONFIG_SKIP_INSTALL_PACKAGES"'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "apply_policy_env: a value containing colons (NO_PROXY-shaped) exports intact with no quote characters" {
  local f="$BATS_TEST_TMPDIR/policy.yaml"
  printf '%s\n' 'env:' \
    '  NO_PROXY: "localhost,127.0.0.1,::1,opencode,rag,squid"' > "$f"
  run bash -c "$SRC"'; apply_policy_env "'"$f"'"; printf "%s" "$NO_PROXY"'
  [ "$status" -eq 0 ]
  [ "$output" = "localhost,127.0.0.1,::1,opencode,rag,squid" ]
  [[ "$output" != *'"'* ]]
}

@test "apply_policy_env: multiple keys under env: are all exported, none carry quote chars" {
  local f="$BATS_TEST_TMPDIR/policy.yaml"
  printf '%s\n' \
    'env:' \
    '  OPENCODE_DISABLE_TELEMETRY: "1"' \
    '  OPENCODE_AUTOUPDATE: "0"' \
    '  DO_NOT_TRACK: "1"' \
    > "$f"
  run bash -c "$SRC"'; apply_policy_env "'"$f"'"; printf "%s|%s|%s" "$OPENCODE_DISABLE_TELEMETRY" "$OPENCODE_AUTOUPDATE" "$DO_NOT_TRACK"'
  [ "$status" -eq 0 ]
  [ "$output" = "1|0|1" ]
}

@test "apply_policy_env: keys outside the env: block are not exported" {
  local f="$BATS_TEST_TMPDIR/policy.yaml"
  printf '%s\n' 'env:' '  FOO: "1"' '' 'other_block:' '  BAR: "2"' > "$f"
  run bash -c "$SRC"'; apply_policy_env "'"$f"'"; printf "foo=%s bar=%s" "${FOO:-unset}" "${BAR:-unset}"'
  [ "$status" -eq 0 ]
  [ "$output" = "foo=1 bar=unset" ]
}

@test "apply_policy_env: missing file is a no-op (exits 0, exports nothing)" {
  run bash -c "$SRC"'; apply_policy_env "/nonexistent/policy.yaml"; echo done'
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "apply_policy_env: matches the real opencode/policy.yaml shipped in this repo" {
  run bash -c "$SRC"'; apply_policy_env "'"$REPO_ROOT"'/opencode/policy.yaml"; printf "%s|%s" "$OPENCODE_DISABLE_TELEMETRY" "$NO_PROXY"'
  [ "$status" -eq 0 ]
  [ "$output" = "1|localhost,127.0.0.1,::1,opencode,rag,squid" ]
}

# --- extra_instruction_paths() --------------------------------------------
# Generic hook: parses OPENCODE_EXTRA_INSTRUCTIONS (space/comma-separated) into
# one path per line, which main() appends to opencode.json's `instructions`.
# The container is `--also`-agnostic; the launcher sets the var. Pure helper —
# takes the raw value as an arg, so it is exercised directly here.

@test "extra_instructions: an unset/empty value prints nothing (guaranteed no-op on the common path)" {
  run bash -c "$SRC"'; extra_instruction_paths ""'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c "$SRC"'; extra_instruction_paths'   # no arg at all -> local default
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extra_instructions: a single path is echoed verbatim" {
  run bash -c "$SRC"'; extra_instruction_paths "/workspace-extra/.opencode-context.md"'
  [ "$status" -eq 0 ]
  [ "$output" = "/workspace-extra/.opencode-context.md" ]
}

@test "extra_instructions: a space/comma list splits, one path per line, empties dropped" {
  run bash -c "$SRC"'; extra_instruction_paths "/a/b.md, /c/d.md   /e/f.md,,"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/a/b.md\n/c/d.md\n/e/f.md')" ]
}

@test "extra_instructions: the instructions-array jq wiring is valid and appends (both absent and present)" {
  # Guards the exact jq fragment §4c appends to cfg_filter per path. bash -n
  # cannot catch a broken jq expression; this does. Absent -> creates the
  # array; present -> appends without dropping existing entries.
  local xi="/workspace-extra/.opencode-context.md"
  local filter='. | .instructions = ((.instructions // []) + [$xi_0])'

  run jq -c --arg xi_0 "$xi" "$filter" <<<'{"theme":"x"}'
  [ "$status" -eq 0 ]
  [ "$output" = "{\"theme\":\"x\",\"instructions\":[\"$xi\"]}" ]

  run jq -c --arg xi_0 "$xi" "$filter" <<<'{"instructions":["AGENTS.md"]}'
  [ "$status" -eq 0 ]
  [ "$output" = "{\"instructions\":[\"AGENTS.md\",\"$xi\"]}" ]
}

# --- extra_allowed_dirs() --------------------------------------------------
# Generic hook: parses OPENCODE_EXTRA_ALLOWED_DIRS (space/comma-separated) into
# one glob per line, which main() folds into opencode.json's
# permission.external_directory as "allow". Sibling of extra_instruction_paths
# for the *access* half of the --also story; same launcher-injected, container-
# agnostic contract. Pure helper — takes the raw value as an arg.

@test "extra_allowed_dirs: an unset/empty value prints nothing (guaranteed no-op on the common path)" {
  run bash -c "$SRC"'; extra_allowed_dirs ""'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c "$SRC"'; extra_allowed_dirs'   # no arg at all -> local default
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extra_allowed_dirs: a single glob is echoed verbatim" {
  run bash -c "$SRC"'; extra_allowed_dirs "/workspace-extra/**"'
  [ "$status" -eq 0 ]
  [ "$output" = "/workspace-extra/**" ]
}

@test "extra_allowed_dirs: a space/comma list splits, one glob per line, empties dropped" {
  run bash -c "$SRC"'; extra_allowed_dirs "/workspace-extra/**, /data/**   /opt/x/**,,"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/workspace-extra/**\n/data/**\n/opt/x/**')" ]
}

@test "extra_allowed_dirs: a glob survives verbatim even when matching paths exist on disk (noglob regression)" {
  # The boot-time footgun: the --also mounts a pattern names already exist when
  # the entrypoint runs, so an unguarded `for p in ${raw}` filename-expands
  # /workspace-extra/** into the leaf dirs and silently drops the wildcard
  # opencode matches on. Create a real matching tree and prove the pattern is
  # emitted literally, not expanded to $d/demo + $d/other.
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/demo" "$d/other"
  run bash -c "$SRC"'; extra_allowed_dirs "'"$d"'/**"'
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "$d/**" ]
}

@test "extra_allowed_dirs: the external_directory jq wiring is valid and folds in (both absent and present)" {
  # Guards the exact jq fragment §4d appends to cfg_filter per glob. bash -n
  # cannot catch a broken jq expression; this does. Absent -> auto-vivifies the
  # permission.external_directory object; present -> adds the key alongside the
  # existing ones without dropping them.
  local xa="/workspace-extra/**"
  local filter='. | .permission.external_directory[$xa_0] = "allow"'

  run jq -c --arg xa_0 "$xa" "$filter" <<<'{"permission":{"edit":"allow","webfetch":"deny","bash":"allow"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "{\"permission\":{\"edit\":\"allow\",\"webfetch\":\"deny\",\"bash\":\"allow\",\"external_directory\":{\"$xa\":\"allow\"}}}" ]

  run jq -c --arg xa_0 "$xa" "$filter" <<<'{"permission":{"external_directory":{"/data/**":"allow"}}}'
  [ "$status" -eq 0 ]
  [ "$output" = "{\"permission\":{\"external_directory\":{\"/data/**\":\"allow\",\"/workspace-extra/**\":\"allow\"}}}" ]
}

# --- mcp_credentials_present() --------------------------------------------
# The single predicate deciding whether a first-party MCP server is "up" — used
# both to wire it into opencode.json (§4b) and to gate its companion *-fetch
# skill (§3a builds MCPS_ENABLED_SET from it). Pure: reads <SVC>_* from the
# environment, returns 0/1. Inline `VAR=val fn` assignments scope the creds to
# just that call.

@test "mcp_credentials_present: API-only service (needs_user=0) is up with BASE_URL + PAT" {
  run bash -c "$SRC"'; JIRA_BASE_URL=http://j JIRA_PAT=t mcp_credentials_present jira 0'
  [ "$status" -eq 0 ]
}

@test "mcp_credentials_present: missing PAT means not up" {
  run bash -c "$SRC"'; JIRA_BASE_URL=http://j mcp_credentials_present jira 0'
  [ "$status" -ne 0 ]
}

@test "mcp_credentials_present: missing BASE_URL means not up" {
  run bash -c "$SRC"'; JIRA_PAT=t mcp_credentials_present jira 0'
  [ "$status" -ne 0 ]
}

@test "mcp_credentials_present: DISABLE_<SVC>_MCP=1 forces not up even with full creds" {
  run bash -c "$SRC"'; JIRA_BASE_URL=http://j JIRA_PAT=t DISABLE_JIRA_MCP=1 mcp_credentials_present jira 0'
  [ "$status" -ne 0 ]
}

@test "mcp_credentials_present: needs_user=1 service (GitLab) also requires <SVC>_USER" {
  run bash -c "$SRC"'; GITLAB_BASE_URL=http://g GITLAB_PAT=t mcp_credentials_present gitlab 1'
  [ "$status" -ne 0 ]   # user missing -> not up
  run bash -c "$SRC"'; GITLAB_BASE_URL=http://g GITLAB_PAT=t GITLAB_USER=me mcp_credentials_present gitlab 1'
  [ "$status" -eq 0 ]   # user present -> up
}

@test "mcp_credentials_present: Bitbucket (needs_user=0, Bearer REST) is up without <SVC>_USER" {
  run bash -c "$SRC"'; BITBUCKET_BASE_URL=http://b BITBUCKET_PAT=t mcp_credentials_present bitbucket 0'
  [ "$status" -eq 0 ]
}

@test "mcp_credentials_present: an entirely unconfigured service is not up" {
  run bash -c "$SRC"'; mcp_credentials_present confluence 0'
  [ "$status" -ne 0 ]
}

# --- skill_gate_ok() ------------------------------------------------------
# Reads a skill's `.requires` file and decides whether it should be linked,
# consulting the PLUGINS_ENABLED_SET / MCPS_ENABLED_SET globals main() §3a builds
# (space-padded strings). One `plugin=`/`mcp=` line per file; fails closed.

@test "skill_gate_ok: plugin gate passes when the plugin is in the enabled set" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'plugin=opencode-pty\n' > "$f"
  run bash -c "$SRC"'; PLUGINS_ENABLED_SET=" superpowers opencode-pty "; skill_gate_ok "'"$f"'"'
  [ "$status" -eq 0 ]
}

@test "skill_gate_ok: plugin gate fails when the plugin is not enabled" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'plugin=opencode-pty\n' > "$f"
  run bash -c "$SRC"'; PLUGINS_ENABLED_SET=" superpowers "; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
}

@test "skill_gate_ok: mcp gate passes/fails on MCPS_ENABLED_SET membership" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'mcp=jira\n' > "$f"
  run bash -c "$SRC"'; MCPS_ENABLED_SET=" jira gitlab "; skill_gate_ok "'"$f"'"'
  [ "$status" -eq 0 ]
  run bash -c "$SRC"'; MCPS_ENABLED_SET=" gitlab "; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
}

@test "skill_gate_ok: whole-word match — a name that is only a substring does not satisfy the gate" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'plugin=pty\n' > "$f"
  run bash -c "$SRC"'; PLUGINS_ENABLED_SET=" opencode-pty "; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
}

@test "skill_gate_ok: a trailing CR is tolerated (CRLF-authored .requires)" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'plugin=opencode-pty\r\n' > "$f"
  run bash -c "$SRC"'; PLUGINS_ENABLED_SET=" opencode-pty "; skill_gate_ok "'"$f"'"'
  [ "$status" -eq 0 ]
}

@test "skill_gate_ok: comment and blank lines are ignored" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf '# needs the plugin\n\nplugin=opencode-pty\n' > "$f"
  run bash -c "$SRC"'; PLUGINS_ENABLED_SET=" opencode-pty "; skill_gate_ok "'"$f"'"'
  [ "$status" -eq 0 ]
}

@test "skill_gate_ok: env gate passes only when the variable equals the required value" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'env=ALLOW_CONFLUENCE_WRITE=1\n' > "$f"
  run bash -c "$SRC"'; ALLOW_CONFLUENCE_WRITE=1; skill_gate_ok "'"$f"'"'
  [ "$status" -eq 0 ]
  run bash -c "$SRC"'; ALLOW_CONFLUENCE_WRITE=0; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
}

@test "skill_gate_ok: env gate fails closed when the variable is unset or truthy-but-not-the-value" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'env=ALLOW_CONFLUENCE_WRITE=1\n' > "$f"
  run bash -c "$SRC"'; unset ALLOW_CONFLUENCE_WRITE; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
  run bash -c "$SRC"'; ALLOW_CONFLUENCE_WRITE=true; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
}

@test "skill_gate_ok: a malformed env gate (no value) fails closed" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'env=ALLOW_CONFLUENCE_WRITE\n' > "$f"
  run bash -c "$SRC"'; ALLOW_CONFLUENCE_WRITE=1; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
}

@test "skill_gate_ok: every line must hold — mcp present but env gate off still fails" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'mcp=confluence\nenv=ALLOW_CONFLUENCE_WRITE=1\n' > "$f"
  run bash -c "$SRC"'; MCPS_ENABLED_SET=" confluence "; ALLOW_CONFLUENCE_WRITE=0; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
  run bash -c "$SRC"'; MCPS_ENABLED_SET=" confluence "; ALLOW_CONFLUENCE_WRITE=1; skill_gate_ok "'"$f"'"'
  [ "$status" -eq 0 ]
}

@test "skill_gate_ok: an unknown key fails closed" {
  local f="$BATS_TEST_TMPDIR/.requires"; printf 'wat=whatever\n' > "$f"
  run bash -c "$SRC"'; PLUGINS_ENABLED_SET=" opencode-pty "; MCPS_ENABLED_SET=" jira "; skill_gate_ok "'"$f"'"'
  [ "$status" -ne 0 ]
}

# --- direct-execution smoke check ------------------------------------------
# Not a unit test of a pure function — a regression guard that the
# main()-wrap refactor didn't change entrypoint.sh's behavior when it's
# actually executed as a script (as opposed to sourced). Every environment
# this suite runs in lacks the image's `dev` user, so the earliest possible
# failure is always the UID/GID remap's `id -u dev` — this pins that exact
# failure mode rather than asserting anything image-specific.

@test "direct execution: fails at the id -u dev step when there is no dev user, same as before the main() refactor" {
  run bash -c 'exec "$ENTRYPOINT" serve'
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev"* ]]
}

# --- MCP gate loop --------------------------------------------------------
# See tests/README.md "What's NOT covered" — the §4b MCP_SERVICES table walk
# reads/writes real filesystem paths under /opt/opencode (MCP_DIR) and
# /etc/opencode (the jq config template) that only exist inside the built
# image. Stubbing that whole layout to unit-test the loop's pure
# on/off-per-service decision would mean re-implementing most of the image's
# filesystem rather than testing the real thing, so it's deliberately skipped
# here. scripts/doctor.sh's `check_mcp` (run against a live container) is
# the real coverage for that logic's runtime behavior.
