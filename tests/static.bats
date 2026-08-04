#!/usr/bin/env bats
#
# Cheap, repo-wide invariants: things that are easy to get out of sync by
# editing one file and forgetting its counterpart (manifest vs. entrypoint vs.
# .env.example vs. Dockerfile; squid ACL-type footguns; every file at least
# parses). None of these need Docker or a running stack.

setup() {
  load common
}

# --- opencode/manifest.json --------------------------------------------------

@test "manifest.json: is valid JSON" {
  run jq empty "$REPO_ROOT/opencode/manifest.json"
  [ "$status" -eq 0 ]
}

@test "manifest.json: manifest_version is 1" {
  run jq -r '.manifest_version' "$REPO_ROOT/opencode/manifest.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "manifest.json: exactly LLM_API_BASE and LLM_API_KEY are required:true" {
  run jq -r '[.env_keys[] | select(.required==true) | .key] | sort | join(",")' \
    "$REPO_ROOT/opencode/manifest.json"
  [ "$status" -eq 0 ]
  [ "$output" = "LLM_API_BASE,LLM_API_KEY" ]
}

@test "manifest.json: every env_keys[].key appears in .env.example" {
  local keys key missing=""
  keys="$(jq -r '.env_keys[].key' "$REPO_ROOT/opencode/manifest.json")"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qE "^${key}=" "$REPO_ROOT/.env.example" || missing="${missing}${key} "
  done <<< "$keys"
  [ -z "$missing" ] || {
    echo "manifest env_keys missing from .env.example: $missing" >&2
    return 1
  }
}

@test "manifest.json: mcps[] matches the directory names under opencode/mcp-servers/ (excluding _lib)" {
  local manifest_mcps dir_mcps
  manifest_mcps="$(jq -r '.mcps[]' "$REPO_ROOT/opencode/manifest.json" | sort)"
  dir_mcps="$(find "$REPO_ROOT/opencode/mcp-servers" -mindepth 1 -maxdepth 1 -type d \
    ! -name _lib -exec basename {} \; | sort)"
  [ "$manifest_mcps" = "$dir_mcps" ]
}

@test "manifest.json: plugins[] matches the plugins built in opencode/Dockerfile's plugins-build stage" {
  local manifest_plugins dockerfile_plugins
  manifest_plugins="$(jq -r '.plugins[]' "$REPO_ROOT/opencode/manifest.json" | sort)"
  dockerfile_plugins="$(grep -oE '/staging/plugins/[a-zA-Z0-9_-]+' "$REPO_ROOT/opencode/Dockerfile" \
    | sed 's#.*/##' | sort -u)"
  [ "$manifest_plugins" = "$dockerfile_plugins" ]
}

@test "manifest.json: every MCP_SERVICES entry in the entrypoint's table appears in mcps[]" {
  local table svc missing=""
  table="$(grep -oE '^MCP_SERVICES="[^"]*"' "$REPO_ROOT/opencode/entrypoint.sh" | sed -E 's/^MCP_SERVICES="//; s/"$//')"
  [ -n "$table" ]
  for entry in $table; do
    svc="${entry%%:*}"
    jq -e --arg s "$svc" '.mcps | index($s) != null' "$REPO_ROOT/opencode/manifest.json" >/dev/null \
      || missing="${missing}${svc} "
  done
  [ -z "$missing" ] || {
    echo "entrypoint MCP_SERVICES not listed in manifest.json mcps[]: $missing" >&2
    return 1
  }
}

# --- squid -------------------------------------------------------------------

@test "squid allowlist.d: every non-comment line is an 'acl allowed_dst dstdomain ...' line" {
  local f line bad=""
  for f in "$REPO_ROOT"/squid/allowlist.d/*.conf; do
    while IFS= read -r line; do
      case "$line" in
        ''|\#*) continue ;;
        'acl allowed_dst dstdomain '*) continue ;;
        *) bad="${bad}${f}: ${line}\n" ;;
      esac
    done < "$f"
  done
  [ -z "$bad" ] || {
    printf '%b' "non-conforming allowlist.d lines (must be \"acl allowed_dst dstdomain ...\"):\n$bad" >&2
    return 1
  }
}

@test "squid.conf: SSL_ports includes 80, 443 and 8090" {
  for port in 80 443 8090; do
    grep -qE "^acl SSL_ports port ${port}([[:space:]]|\$)" "$REPO_ROOT/squid/squid.conf" \
      || { echo "SSL_ports missing port $port" >&2; return 1; }
  done
}

@test "squid.conf: the denial-logging access_log lines appear before the terminal 'access_log none'" {
  local file="$REPO_ROOT/squid/squid.conf"
  local none_line deny_lines
  none_line="$(grep -n '^access_log none' "$file" | head -1 | cut -d: -f1)"
  [ -n "$none_line" ]
  deny_lines="$(grep -n '^access_log stdio:' "$file" | cut -d: -f1)"
  [ -n "$deny_lines" ]
  local ln
  for ln in $deny_lines; do
    [ "$ln" -lt "$none_line" ] || {
      echo "access_log stdio: line $ln is not before the terminal 'access_log none' at line $none_line" >&2
      return 1
    }
  done
}

# --- shell: syntax (+ shellcheck if available) --------------------------------

shell_files() {
  { find "$REPO_ROOT" -name '*.sh' \
      -not -path "$REPO_ROOT/tests/.bats/*" -not -path "$REPO_ROOT/.git/*"
    printf '%s\n' "$REPO_ROOT/opencode/git-guard" "$REPO_ROOT/scripts/opencode"
  } | sort -u
}

@test "shell: every *.sh + opencode/git-guard + opencode/entrypoint.sh passes bash -n" {
  local f bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    bash -n "$f" 2>/dev/null || bad="${bad}${f} "
  done < <(shell_files)
  [ -z "$bad" ] || {
    echo "bash -n failed for: $bad" >&2
    return 1
  }
}

@test "shell: shellcheck (error severity only) on the same file set, or skipped if shellcheck is absent" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  local f bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    shellcheck --severity=error "$f" >/dev/null || bad="${bad}${f} "
  done < <(shell_files)
  [ -z "$bad" ] || {
    echo "shellcheck (error severity) failed for: $bad" >&2
    return 1
  }
}

# --- node: syntax --------------------------------------------------------------

@test "node: every opencode/mcp-servers/**/*.js passes node --check" {
  local f bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    node --check "$f" 2>/dev/null || bad="${bad}${f} "
  done < <(find "$REPO_ROOT/opencode/mcp-servers" -name '*.js' -not -path '*/node_modules/*')
  [ -z "$bad" ] || {
    echo "node --check failed for: $bad" >&2
    return 1
  }
}

# --- .env.example <-> scripts/doctor.sh consistency --------------------------

@test ".env.example: every var in doctor.sh's required-keys list exists in .env.example" {
  local vars var missing=""
  vars="$(sed -n "/for var in LLM_API_BASE LLM_API_KEY/,/; do/p" "$REPO_ROOT/scripts/doctor.sh" \
    | tr -d '\\' | grep -oE '[A-Z_][A-Z0-9_]*')"
  # Drop the loop keywords ("for"/"var"/"in"/"do") that the grep also matches.
  for var in $vars; do
    case "$var" in for|var|in|do) continue ;; esac
    grep -qE "^${var}=" "$REPO_ROOT/.env.example" || missing="${missing}${var} "
  done
  [ -z "$missing" ] || {
    echo "doctor.sh required keys missing from .env.example: $missing" >&2
    return 1
  }
}

@test ".env.example: doctor.sh's optional Bitbucket keys also exist in .env.example" {
  for var in BITBUCKET_USER BITBUCKET_PAT; do
    grep -qE "^${var}=" "$REPO_ROOT/.env.example"
  done
}

# --- JSON files parse ----------------------------------------------------------

@test "every tracked *.json file is valid JSON" {
  local f bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    jq empty "$f" >/dev/null 2>&1 || bad="${bad}${f} "
  done < <(cd "$REPO_ROOT" && git ls-files '*.json')
  [ -z "$bad" ] || {
    echo "invalid JSON: $bad" >&2
    return 1
  }
}

# --- GitLab MCP write surface ------------------------------------------------
#
# The gate is only as good as its weakest tool. These are structural checks
# against the source, so tool #7 cannot quietly skip a step that tools 1-6 all
# take — which is exactly the kind of omission nobody notices in review.

@test "gitlab MCP: every write tool has a dispatch case" {
  src="$REPO_ROOT/opencode/mcp-servers/gitlab/index.js"
  names="$(sed -n '/^const WRITE_TOOLS = \[/,/^\];/p' "$src" | grep -o 'name: "[a-z_]*"' | cut -d'"' -f2)"
  [ -n "$names" ]
  missing=""
  for n in $names; do
    grep -q "case \"$n\":" "$src" || missing="${missing}${n} "
  done
  [ -z "$missing" ] || { echo "write tools with no dispatch case: $missing" >&2; false; }
}

@test "gitlab MCP: every write handler calls assertWriteAllowed" {
  src="$REPO_ROOT/opencode/mcp-servers/gitlab/index.js"
  names="$(sed -n '/^const WRITE_TOOLS = \[/,/^\];/p' "$src" | grep -o 'name: "[a-z_]*"' | cut -d'"' -f2)"
  missing=""
  for n in $names; do
    # snake_case tool name -> camelCase handler, then read that function body.
    fn="$(echo "$n" | awk -F_ '{printf "%s", $1; for(i=2;i<=NF;i++) printf "%s%s", toupper(substr($i,1,1)), substr($i,2)}')"
    body="$(sed -n "/^async function ${fn}(/,/^}/p" "$src")"
    [ -n "$body" ] || { missing="${missing}${n}(no handler) "; continue; }
    echo "$body" | grep -q "assertWriteAllowed" || missing="${missing}${n} "
  done
  [ -z "$missing" ] || { echo "write handlers missing assertWriteAllowed: $missing" >&2; false; }
}

@test "gitlab MCP: the advertised tool list is gated on the write switch" {
  src="$REPO_ROOT/opencode/mcp-servers/gitlab/index.js"
  grep -q 'const TOOLS = WRITES_ENABLED ? \[...READ_TOOLS, ...WRITE_TOOLS\] : READ_TOOLS' "$src"
}

@test "gitlab MCP: the dispatcher refuses write tools independently of the listing" {
  # Hiding a tool from tools/list is not enforcement — a client can call a name
  # it was never offered. The switch must be re-checked on the call path.
  src="$REPO_ROOT/opencode/mcp-servers/gitlab/index.js"
  handler="$(sed -n '/setRequestHandler(CallToolRequestSchema/,/^});/p' "$src")"
  echo "$handler" | grep -q 'WRITE_TOOL_NAMES.has(name) && !WRITES_ENABLED'
}

@test "gitlab MCP: no write tool mutates issue labels or state" {
  # In the symphony workflow the label IS the workflow state and the
  # orchestrator owns every transition. An agent able to relabel its own issue
  # could mark its work reviewed, or feed itself work forever. Merging is a
  # human decision. Neither capability may appear here.
  src="$REPO_ROOT/opencode/mcp-servers/gitlab/index.js"
  ! grep -qE 'state_event|"PUT", `/projects/\$\{encodeProjectId\(project\)\}/issues/\$\{issueIid\}`' "$src"
  ! grep -q '/merge_requests/${mrIid}/merge' "$src"
}
