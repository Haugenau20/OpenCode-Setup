---
name: confluence-fetch
description: "Fetches documentation and wiki context from the internal Confluence instance using the Confluence MCP tools — reading pages by id or space+title, CQL search, browsing a space's page tree, and listing spaces. Use whenever the user wants to look up, find, read, search, or cross-reference Confluence pages, runbooks, design docs, onboarding guides, or any wiki content — even if they don't say 'Confluence' explicitly. Trigger phrases include 'find the runbook for X', 'what does the wiki say about Y', 'read the onboarding page', 'search confluence for Z', 'what spaces do we have', 'find the design doc for service A', 'is there documentation on B'. Read-only — for creating or editing pages use the confluence-write skill instead."
---

# Confluence MCP — Agent Skill

Use the Confluence MCP server when you need **documentation / wiki context** —
e.g. reading a page, finding a runbook or design doc, searching the wiki, or
browsing a space's page tree.

Confluence is a **documentation system, not a code or issue tracker**. For
*source code* use the GitLab/Bitbucket skills; for *issues/tickets* use the Jira
skill; for *published artifacts* use JFrog. A common cross-reference is
**Jira → Confluence** (a ticket links to a spec page) or **code → Confluence**
(a service's runbook lives in the wiki).

Key vocabulary: a **space** is a top-level container identified by a **space
key** (e.g. `ENG`, `OPS`). A **page** has a numeric **content id** and lives in
exactly one space, nested under a parent (pages form a tree).

---

## Workflow patterns

### 0. Discovering spaces (when the space key isn't known)

```
1. confluence_list_spaces()   → key, name, type for each space
```

Run this first if the user names a topic but not a space; use the `key` to scope
a search.

### 1. Reading a known page

```
# by id (fastest, if you have it):
1. confluence_get_page(id="123456")

# by space + exact title:
2. confluence_get_page(spaceKey="ENG", title="Deployment Runbook")
```

### 2. Searching the wiki (CQL)

```
1. confluence_search(cql='space = ENG AND type = page AND text ~ "deployment"')
2. confluence_get_page(id="<id from results>")   → read the best hit in full
```

CQL is the powerful path — filter by `space`, `type`, `title ~ "..."`,
`text ~ "..."`, `creator`, `lastmodified`, and combine with AND/OR.

### 3. Browsing a space's page tree

```
1. confluence_get_page(spaceKey="OPS", title="Home")   → get the root page id
2. confluence_get_page_children(id="<root id>")        → list direct children
3. confluence_get_page_children(id="<child id>")       → drill down
```

---

## Tool reference

### `confluence_get_page`
- Fetch one page's full content + metadata. Provide **either** `id`, **or** both
  `spaceKey` and `title` (exact match). Body is rendered from Confluence storage
  format to plain text — a simplified rendering; macro-heavy pages may read
  better in the browser (a link is always included).
- `format="storage"` returns the raw storage-format XHTML instead. Only needed
  when you are about to *edit* the page (see the `confluence-write` skill) — the
  default text rendering is lossy and cannot be written back.

### `confluence_search`
- CQL (Confluence Query Language) search — the main discovery tool. Returns
  title, type, space and a link per hit. `limit` defaults to 20 (max 50).
- Examples:
  - `space = ENG AND type = page AND text ~ "kafka"`
  - `title ~ "runbook" AND space in (OPS, SRE)`
  - `creator = currentUser() AND lastmodified > now("-7d")`

### `confluence_get_page_children`
- List the direct child pages of a page id — for walking a space's tree.

### `confluence_list_spaces`
- List spaces (key, name, type). Use to discover a space key before a scoped
  search. `limit` defaults to 50 (max 100).

### `confluence_get_current_user`
- The authenticated user (username/email). Call before a CQL search using
  `creator = currentUser()` or to answer "my pages" questions.

---

## Key parameters

| Parameter | Description                                         | Example                          |
|-----------|-----------------------------------------------------|----------------------------------|
| id        | Numeric page/content id                             | `123456`                         |
| spaceKey  | Space key (with `title`, or to scope a search)      | `ENG`                            |
| title     | Exact page title (with `spaceKey`)                  | `Deployment Runbook`             |
| cql       | Confluence Query Language string                    | `space = ENG AND text ~ "kafka"` |
| limit     | Max results                                         | `20`                             |

---

## Tips

- **Have an id?** Use `confluence_get_page(id=...)` — it's the most direct read.
  Only fall back to `spaceKey`+`title` when you don't have the id.
- **Searching?** `confluence_search` with CQL is the discovery tool — narrow with
  `space = ...` and `type = page` to cut noise, then read the top hit's full body
  with `confluence_get_page`.
- `title` lookups require an **exact** title match; if it fails, search by
  `text ~ "..."` instead.
- Page bodies are a **simplified text rendering** of Confluence storage format —
  good for reading and quoting, but tables/macros may lose structure. The page
  link is always included for the full fidelity view.
- The tools in **this** skill are read-only — they never change anything. Writing
  is a separate, opt-in capability: the Confluence MCP grows `create_page`,
  `update_page`, `append_to_page` and `add_comment` only when
  `ALLOW_CONFLUENCE_WRITE=1` is set in `.env`, and the **`confluence-write`**
  skill covers them. Deleting pages is never possible from either skill.
