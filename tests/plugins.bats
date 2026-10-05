#!/usr/bin/env bats

setup() {
  load common
  export BUNDLE="$BATS_TEST_TMPDIR/bundle"
  export USER_CFG="$BATS_TEST_TMPDIR/config"
  mkdir -p "$BUNDLE/plugins" "$USER_CFG/plugin"
  # Copy the exact package that Docker stages, including its entries manifest.
  cp -R "$REPO_ROOT/opencode/plugins/merge-system" "$BUNDLE/plugins/"
  mkdir -p "$BUNDLE/plugins/optional"
  printf 'optional.js=index.js\n' > "$BUNDLE/plugins/optional/entries"
  touch "$BUNDLE/plugins/optional/index.js"
}

@test "merge-system: system prompt regression cases" {
  run node --test "$REPO_ROOT/tests/merge-system.test.mjs"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "plugins: merge-system is linked and importable with ENABLED_PLUGINS unset" {
  run bash -c '
    source "$ENTRYPOINT"
    unset ENABLED_PLUGINS
    PLUGINS_ENABLED_SET="$(enabled_plugins)"
    symlink_plugins
    test -L "$USER_CFG/plugin/merge-system.js"
    test ! -e "$USER_CFG/plugin/optional.js"
    node --input-type=module -e '\''
      import { pathToFileURL } from "node:url";
      const { default: plugin } = await import(pathToFileURL(process.argv[1]));
      const output = {system: ["main", "<date-awareness>today</date-awareness>"]};
      await (await plugin())["experimental.chat.system.transform"]({model: {id: "<model>"}}, output);
      if (output.system.length !== 1) process.exit(1);
    '\'' "$USER_CFG/plugin/merge-system.js"
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "plugins: empty opt-in list and disabled.yaml cannot disable merge-system" {
  printf 'plugins:\n  - merge-system\n' > "$USER_CFG/disabled.yaml"
  run bash -c '
    source "$ENTRYPOINT"
    DISABLED_FILE="$USER_CFG/disabled.yaml"
    ENABLED_PLUGINS=""
    PLUGINS_ENABLED_SET="$(enabled_plugins)"
    symlink_plugins
    test -L "$USER_CFG/plugin/merge-system.js"
    test ! -e "$USER_CFG/plugin/optional.js"
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "plugins: restart removes optional links but keeps merge-system and unrelated files" {
  touch "$USER_CFG/plugin/custom.js"
  ln -s "$BUNDLE/plugins/removed/index.js" "$USER_CFG/plugin/stale.js"
  run bash -c '
    source "$ENTRYPOINT"
    ENABLED_PLUGINS="\"optional, merge-system\""
    PLUGINS_ENABLED_SET="$(enabled_plugins)"
    symlink_plugins
    test -L "$USER_CFG/plugin/optional.js"
    test -L "$USER_CFG/plugin/merge-system.js"
    test ! -L "$USER_CFG/plugin/stale.js"
    ENABLED_PLUGINS=""
    PLUGINS_ENABLED_SET="$(enabled_plugins)"
    symlink_plugins
    test ! -L "$USER_CFG/plugin/optional.js"
    test -L "$USER_CFG/plugin/merge-system.js"
    test -f "$USER_CFG/plugin/custom.js"
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "plugins: shipped policy exports npm offline mode before startup" {
  run bash -c '
    source "$ENTRYPOINT"
    unset NPM_CONFIG_OFFLINE
    apply_policy_env "$REPO_ROOT/opencode/policy.yaml"
    bash -c '\''test "$NPM_CONFIG_OFFLINE" = true'\''
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
