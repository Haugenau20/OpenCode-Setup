#!/usr/bin/env bats

setup() {
  load common
  LAUNCHER="$REPO_ROOT/opencode/mcp-servers/teamcity/launch.sh"
}

@test "TeamCity launcher rejects names outside teamcity1 through teamcity10" {
  run bash "$LAUNCHER" teamcity11
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid TeamCity instance"* ]]
}

@test "TeamCity launcher requires the selected instance's complete pair" {
  run env TEAMCITY1_BASE_URL=http://teamcity1:8111 TEAMCITY2_PAT=wrong-instance \
    bash "$LAUNCHER" teamcity1
  [ "$status" -ne 0 ]
  [[ "$output" == *"TEAMCITY1_BASE_URL, TEAMCITY1_PAT"* ]]
}

@test "TeamCity launcher does not accept an unnumbered fallback PAT" {
  run env TEAMCITY1_BASE_URL=http://teamcity1:8111 TEAMCITY_PAT=fallback \
    bash "$LAUNCHER" teamcity1
  [ "$status" -ne 0 ]
  [[ "$output" == *"TEAMCITY1_BASE_URL, TEAMCITY1_PAT"* ]]
}
