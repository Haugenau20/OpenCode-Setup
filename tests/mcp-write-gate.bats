#!/usr/bin/env bats
#
# opencode/mcp-servers/_lib/write_gate.js is deliberately dependency-free so it
# can be exercised with plain node, without any server's node_modules (which
# only exist inside the built image). The GitLab MCP's write surface is the
# first consumer; the module is service-agnostic so a second one costs nothing.

setup() {
  load common
  GATE="$REPO_ROOT/opencode/mcp-servers/_lib/write_gate.js"
  [ -f "$GATE" ] || skip "write_gate.js not present"
  command -v node >/dev/null || skip "node not installed"
}

# gate <js> — evaluate an expression against the module; prints the result, or
# "THREW: <message>" so a refusal can be asserted on as ordinary output.
gate() {
  run node --input-type=module -e "
    import * as g from '${GATE}';
    try { console.log(JSON.stringify(($1))); }
    catch (e) { console.log('THREW: ' + e.message); }
  "
}

# --- the switch --------------------------------------------------------------

@test "writes are off when the switch is unset" {
  gate "g.writeEnabled('GITLAB', {})"
  [ "$output" = "false" ]
}

@test "writes are off for any value other than 1" {
  gate "[g.writeEnabled('GITLAB',{GITLAB_ALLOW_WRITE:'0'}), g.writeEnabled('GITLAB',{GITLAB_ALLOW_WRITE:'true'}), g.writeEnabled('GITLAB',{GITLAB_ALLOW_WRITE:'yes'})]"
  [ "$output" = "[false,false,false]" ]
}

@test "writes are on for exactly 1" {
  gate "g.writeEnabled('GITLAB', {GITLAB_ALLOW_WRITE:'1'})"
  [ "$output" = "true" ]
}

@test "the switch is per-service" {
  gate "g.writeEnabled('GITLAB', {CONFLUENCE_ALLOW_WRITE:'1'})"
  [ "$output" = "false" ]
}

# --- the project allowlist ---------------------------------------------------

@test "an empty allowlist permits any project" {
  gate "g.projectAllowed('anything/at-all', g.parseProjectAllowlist(''))"
  [ "$output" = "true" ]
}

@test "allowlist accepts comma and whitespace separators" {
  gate "g.parseProjectAllowlist('a/b, c/d  e/f')"
  [ "$output" = '["a/b","c/d","e/f"]' ]
}

@test "an exact project match is permitted" {
  gate "g.projectAllowed('mygroup/service', g.parseProjectAllowlist('mygroup/service'))"
  [ "$output" = "true" ]
}

@test "a group prefix admits projects beneath it" {
  gate "g.projectAllowed('mygroup/service', g.parseProjectAllowlist('mygroup'))"
  [ "$output" = "true" ]
}

@test "prefix matching respects path segments" {
  gate "g.projectAllowed('mygroup-evil/service', g.parseProjectAllowlist('mygroup'))"
  [ "$output" = "false" ]
}

@test "a project outside the allowlist is refused" {
  gate "g.projectAllowed('other/prod', g.parseProjectAllowlist('mygroup/service'))"
  [ "$output" = "false" ]
}

@test "matching ignores case, .git and surrounding slashes" {
  gate "g.projectAllowed('/MyGroup/Service.git/', g.parseProjectAllowlist('mygroup/service'))"
  [ "$output" = "true" ]
}

@test "numeric project ids work like paths" {
  gate "[g.projectAllowed('42', g.parseProjectAllowlist('42')), g.projectAllowed('43', g.parseProjectAllowlist('42'))]"
  [ "$output" = "[true,false]" ]
}

@test "an empty project is refused against a non-empty allowlist" {
  gate "g.projectAllowed('', g.parseProjectAllowlist('mygroup'))"
  [ "$output" = "false" ]
}

# --- assertWriteAllowed ------------------------------------------------------

@test "assertWriteAllowed refuses when the switch is off, and names the switch" {
  gate "g.assertWriteAllowed('GITLAB','any/proj',{})"
  [[ "$output" == THREW:* ]]
  [[ "$output" == *"GITLAB_ALLOW_WRITE=1"* ]]
}

@test "assertWriteAllowed passes when the switch is on and no allowlist is set" {
  gate "(g.assertWriteAllowed('GITLAB','any/proj',{GITLAB_ALLOW_WRITE:'1'}), 'ok')"
  [ "$output" = '"ok"' ]
}

@test "assertWriteAllowed refuses a project outside the allowlist" {
  gate "g.assertWriteAllowed('GITLAB','other/prod',{GITLAB_ALLOW_WRITE:'1',GITLAB_WRITE_PROJECTS:'mygroup/sandbox'})"
  [[ "$output" == THREW:* ]]
  [[ "$output" == *"other/prod"* ]]
  [[ "$output" == *"mygroup/sandbox"* ]]
}

@test "assertWriteAllowed permits a project inside the allowlist" {
  gate "(g.assertWriteAllowed('GITLAB','mygroup/sandbox',{GITLAB_ALLOW_WRITE:'1',GITLAB_WRITE_PROJECTS:'mygroup/sandbox'}), 'ok')"
  [ "$output" = '"ok"' ]
}

@test "an allowlist alone does not enable writes" {
  gate "g.assertWriteAllowed('GITLAB','mygroup/sandbox',{GITLAB_WRITE_PROJECTS:'mygroup/sandbox'})"
  [[ "$output" == THREW:* ]]
}

# --- the reserved label namespace -------------------------------------------
#
# Workflow state IS a `<prefix>::<state>` label and the orchestrator owns it.
# An agent that could set one could mark its own work reviewed, or file itself
# unbounded new work. Refused at the tool boundary, not just in a prompt.

@test "reserved labels are detected regardless of case or padding" {
  gate "g.findReservedLabels(['bug','  Symphony::Todo  ','ok'], 'symphony')"
  [ "$output" = '["  Symphony::Todo  "]' ]
}

@test "a similarly-named label is not reserved" {
  gate "g.findReservedLabels(['symphonic::todo','symphony-ish','symphony'], 'symphony')"
  [ "$output" = "[]" ]
}

@test "assertNoReservedLabels throws and explains who owns the namespace" {
  gate "g.assertNoReservedLabels(['symphony::todo'], 'symphony')"
  [[ "$output" == THREW:* ]]
  [[ "$output" == *"symphony::todo"* ]]
  [[ "$output" == *"orchestrator"* ]]
}

@test "assertNoReservedLabels permits ordinary labels" {
  gate "(g.assertNoReservedLabels(['bug','priority::1'], 'symphony'), 'ok')"
  [ "$output" = '"ok"' ]
}

@test "assertNoReservedLabels tolerates undefined labels" {
  gate "(g.assertNoReservedLabels(undefined, 'symphony'), 'ok')"
  [ "$output" = '"ok"' ]
}

@test "a custom prefix is honoured" {
  gate "g.findReservedLabels(['bot::todo'], 'bot')"
  [ "$output" = '["bot::todo"]' ]
}
