---
name: jfrog-fetch
description: "Fetches artifact and build context from the internal JFrog Artifactory instance using the JFrog MCP tools — repositories, artifact/GAVC/latest-version search, storage item info (folder browsing, checksums, sizes), text artifact contents (poms/manifests), and CI build-info. Use whenever the user wants to look up, find, search, browse, or cross-reference Artifactory/JFrog artifacts, dependencies, or published builds — even if they don't say 'JFrog' explicitly. Trigger phrases include 'what's the latest version of com.acme:app', 'find the artifact foo-1.2.jar', 'what repos do we have', 'read the pom for X', 'what's published under libs-release-local', 'which builds exist', 'is dependency Y in Artifactory'. Read-only."
---

# JFrog Artifactory MCP — Agent Skill

Use the JFrog MCP server when you need **artifact, dependency, or build
context** — e.g. resolving the latest version of a library, finding where an
artifact lives, browsing a repository tree, reading a published `.pom` /
`package.json`, or checking which CI builds have been published.

JFrog is an **artifact repository, not a git remote** — there is no clone/push
and no code-review concept here. For *source code* and MRs/PRs, use the GitLab
or Bitbucket skills instead; use JFrog for the *published artifacts* those
builds produce. A common cross-reference is **GitLab/Bitbucket → JFrog**:
trace a project to the artifact coordinates it publishes, then look those up
here.

Key vocabulary: a **repository key** (`repoKey`, e.g. `libs-release-local`)
identifies a repo; artifacts within it are addressed by a **path**. Maven
artifacts also have **GAVC** coordinates (groupId / artifactId / version /
classifier).

---

## Workflow patterns

### 0. Finding the right repository (when not already known)

```
1. jfrog_list_repositories(packageType="maven")  → discover repos by type/package
```

Returns key, type, packageType, url, description. Run this first if the user
hasn't given an exact `repoKey`. Use the `key` as the `repoKey` argument for
the storage/file tools.

### 1. Resolving the latest version of a dependency

```
1. jfrog_latest_version(g="com.acme", a="app")          → the single latest version
   # optionally scope a release line with v="1.2.*" or repos="libs-release-local"
```

### 2. Finding where an artifact lives

```
1. jfrog_search_artifacts(name="app-1.2.0.jar")   → quick search by file name
   # or, for Maven coordinates:
2. jfrog_gavc_search(g="com.acme", a="app", v="1.2.0")
```

Both return artifact API URIs; the `repoKey` and path are embedded in the URI.

### 3. Browsing a repository and reading a manifest

```
1. jfrog_get_item_info(repoKey="libs-release-local", path="com/acme/app")  → list children
2. jfrog_get_item_info(repoKey=..., path="com/acme/app/1.2.0")            → drill down
3. jfrog_get_file(repoKey=..., path="com/acme/app/1.2.0/app-1.2.0.pom")    → read the pom
```

### 4. Inspecting published CI builds

```
1. jfrog_list_builds()                  → all published build names
2. jfrog_get_build(buildName="my-app")  → run history (build numbers) for one build
```

---

## Tool reference

### `jfrog_list_repositories`
- Optional `type` (local/remote/virtual/federated/distribution) and
  `packageType` (maven, npm, docker, pypi, generic, ...). Call when the repo
  key is unknown. The **discovery tool**.

### `jfrog_get_repository`
- Full config for one `repoKey` — type, packageType, layout, and (remote/virtual)
  upstream URL or aggregated members.

### `jfrog_search_artifacts`
- Quick search by file `name` (or fragment), optionally scoped with `repos`.
  Returns matching artifact URIs. Best when you know part of a file name.

### `jfrog_gavc_search`
- Maven coordinate search — supply at least one of `g`/`a`/`v`/`c`. Use to find
  all versions of a module or a specific artifact.

### `jfrog_latest_version`
- Latest version for Maven `g` + `a`. Pass `v` as a wildcard prefix (`1.2.*`)
  to scope to a release line. Returns one version string.

### `jfrog_get_item_info`
- Storage metadata for a `repoKey` + `path`. Folders list `children` (browse the
  tree); files return size, mimeType, checksums, and the download URI. Empty
  `path` inspects the repo root.

### `jfrog_get_file`
- Raw contents of a **text** artifact (`.pom`, `package.json`, manifests,
  properties). Binary artifacts are returned as metadata only — use
  `jfrog_get_item_info` / the download URI for those.

### `jfrog_list_builds` / `jfrog_get_build`
- `list_builds` returns all published build names; `get_build` returns the run
  history (build numbers) for one name.

---

## Key parameters

| Parameter   | Description                                          | Example                       |
|-------------|------------------------------------------------------|-------------------------------|
| repoKey     | Repository key — use `jfrog_list_repositories` if unknown | `libs-release-local`     |
| path        | Path within a repo, no leading slash                  | `com/acme/app/1.2.0/app-1.2.0.pom` |
| g / a / v / c | Maven groupId / artifactId / version / classifier   | `com.acme` / `app` / `1.2.0`  |
| name        | File name or fragment for quick search                | `app-1.2.0.jar`               |
| repos       | Comma-separated repos to scope a search to            | `libs-release-local,libs-snapshot-local` |
| packageType | Package-type filter for repo discovery                | `maven`, `npm`, `docker`      |

---

## Tips

- **Discover the repo first** with `jfrog_list_repositories` when you don't
  already have an exact `repoKey` — the storage/file tools need it.
- For "what's the newest version" questions, `jfrog_latest_version` is the
  fastest path; fall back to `jfrog_gavc_search` if you need to see *all*
  versions or the artifact isn't Maven-layout.
- `jfrog_get_file` is for **text** artifacts (poms, manifests). It won't dump
  binaries — those come back as metadata only; use `jfrog_get_item_info` for
  size/checksums/download URI instead.
- Reading a published `.pom` is the quickest way to understand an artifact's
  declared dependencies without cloning the source repo.
- This MCP is **read-only** — it never deploys, deletes, or promotes artifacts.
