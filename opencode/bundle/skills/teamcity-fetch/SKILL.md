---
name: teamcity-fetch
description: Inspect projects, build configurations, builds, logs, tests, problems, and changes across the configured TeamCity instances.
---

# TeamCity fetch

Use this skill for every TeamCity lookup. Up to ten independent MCP providers
may be present: `teamcity1` through `teamcity10`. Each provider is connected to
one TeamCity server with a PAT issued by that same instance.

## Pick the instance first

- If the user names an instance, use only that provider.
- If the repository, build URL, or prior context identifies an instance, state
  the inference briefly and use it.
- Otherwise ask which TeamCity instance to use. Do not query all ten merely to
  discover where something lives.
- Never reuse a result, locator, build id, or PAT assumption across instances.
  IDs are local to an instance.

## Typical workflow

1. Call `get_server_info` when confirming the selected connection or version.
2. Discover with `list_projects` and `list_build_configurations`.
3. Narrow builds with `list_builds` and a TeamCity locator, for example
   `buildType:(id:Project_Build),branch:main,status:FAILURE`.
4. Use `get_build` for the selected build.
5. Diagnose with `get_build_problems`, `get_build_tests`, `get_build_changes`,
   and finally `get_build_log` when the structured endpoints are insufficient.
6. Always name the TeamCity instance in the answer and preserve its `webUrl`
   when the API returned one.

## Safety and scale

The shipped tools are GET-only. Do not bypass them with curl to trigger,
cancel, pin, tag, or otherwise mutate builds. Keep collection counts small,
use locators and fields to narrow responses, and request logs only after a
specific build has been identified.
