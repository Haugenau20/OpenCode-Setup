---
name: confluence-write
description: "Creates and edits pages on the internal Confluence instance using the Confluence MCP write tools — creating a page in a space, replacing or appending to an existing page's body, retitling, and commenting. Use whenever the user wants to write, publish, document, draft, update, or post something TO Confluence or the wiki — e.g. 'write a Confluence page for this service', 'document this system on the wiki', 'publish these notes to Confluence', 'add a section to the runbook', 'update the design doc', 'fix the deployment page', 'comment on that page'. For reading, searching, or browsing Confluence use confluence-fetch instead. Only available when ALLOW_CONFLUENCE_WRITE=1."
---

# Confluence MCP (write) — Agent Skill

This skill covers **changing** Confluence. Reading, searching and browsing live
in **`confluence-fetch`** — use that to find things, this to write them.

These tools only exist because `ALLOW_CONFLUENCE_WRITE=1` is set in `.env`. On a
default install the Confluence MCP is read-only and this skill is not loaded.

**Writes are real and immediate.** There is no draft state and no preview: a
`create_page` call publishes a live page in the space, visible to everyone with
access to it. Every change is recorded in the page's version history under the
`CONFLUENCE_PAT` owner's name, so a bad edit is recoverable ("Restore this
version" in the browser) — but a page created by mistake still has to be
deleted by hand, and **these tools cannot delete anything**.

---

## Before writing

1. **Confirm where it goes.** A page needs a space key and, almost always, a
   parent page. If the user hasn't said, ask — or use `confluence_list_spaces`
   and `confluence_search` to propose one and confirm. Creating a page at the
   root of the wrong space is the single most annoying mistake to clean up.
2. **Check it doesn't already exist.** Search before creating
   (`confluence_search` with `title ~ "..."`). Titles must be unique within a
   space; a duplicate is rejected with a 400. If a page on the topic already
   exists, updating it is usually what the user actually wants.
3. **Match the house style.** Read a sibling or the parent page first
   (`confluence_get_page`) — spaces tend to have a conventional structure
   (Overview / Architecture / Operations / Contacts) worth following.

---

## Workflow patterns

### Publishing a new page

```
1. confluence_list_spaces()                             → find the space key
2. confluence_search(cql='space = ENG AND title ~ "billing"')
                                                        → does it exist already?
3. confluence_get_page(spaceKey="ENG", title="Services") → get the parent's id
4. confluence_create_page(
       spaceKey="ENG",
       title="Billing Reconciler",
       parentId="123456",
       format="wiki",
       body="h1. Overview\n\nWhat the system does...")
```

### Editing an existing page

```
1. confluence_get_page(id="123456", format="storage")   → the EXACT current markup
2. confluence_update_page(id="123456", body="<full new body>",
                          versionComment="Document the retry behaviour")
```

`update_page` **replaces the entire body**. Read with `format="storage"` first
and send back the whole document with your changes folded in — the default
`format="text"` rendering is lossy and must never be written back, as it would
destroy every table, macro and link on the page.

### Adding a section without touching the rest

```
1. confluence_append_to_page(id="123456", format="wiki",
                             body="h2. Troubleshooting\n\n...")
```

Prefer this over `update_page` whenever you are only adding — it needs no read,
cannot clobber existing content, and cannot lose a concurrent edit.

---

## Tool reference

### `confluence_create_page`
- Creates a page. `spaceKey`, `title` and `body` are required; `parentId` nests
  it under an existing page (omit → space root, rarely what you want).
- Returns the new page's id and URL.

### `confluence_update_page`
- Replaces `body` and/or `title` of an existing page. Omit `body` to rename
  only; omit `title` to keep the current one.
- `versionComment` shows up in the page history — always pass one, it is what a
  human reads when trying to work out what changed.
- Version numbers are handled for you (the tool reads the page and increments).
  A 409 means someone else edited it in between: re-read and redo the change.

### `confluence_append_to_page`
- Appends to the end of the body, leaving existing content untouched.

### `confluence_add_comment`
- Posts a comment on a page. Use for a note or question about the content;
  use `update_page`/`append_to_page` for the content itself.

---

## Body format

Both `storage` and `wiki` are accepted via the `format` parameter.

| format              | What it is                        | When to use                                    |
|---------------------|-----------------------------------|------------------------------------------------|
| `storage` (default) | Confluence storage-format XHTML   | Editing an existing page (round-trips exactly) |
| `wiki`              | Confluence wiki markup            | Authoring new prose by hand (much easier)      |

**Markdown is not supported** — passing markdown as `storage` publishes a page
of literal `##` and `**` characters. Convert it to one of the two formats above
first.

### Wiki markup cheat sheet (`format="wiki"`)

```
h1. Heading 1
h2. Heading 2

Plain paragraph with *bold*, _italic_ and {{monospace}}.

* bullet
** nested bullet
# numbered item

|| Header || Header ||
| cell    | cell    |

{code:language=bash}
./run.sh --once
{code}

{info}Callout box{info}
[Link text|https://example.internal/path]
```

### Storage format (`format="storage"`)

Well-formed XHTML: `<h1>Title</h1><p>Text</p><ul><li>item</li></ul>`. Every tag
must be closed and every bare `&` written `&amp;` — Confluence rejects the whole
write with a 400 otherwise. Macros are `<ac:structured-macro>` elements; the
reliable way to get one right is to copy it out of an existing page read with
`format="storage"`.

---

## Tips

- **Always pass `versionComment`** on updates. The history is the audit trail.
- **Append beats replace.** If the change is additive, use `append_to_page`.
- **Report the URL back** to the user after every write — that is what they need
  to check the result.
- **Never delete.** These tools can't, by design. If a page must go, tell the
  user to delete it in the browser.
- Writing acts as the `CONFLUENCE_PAT` owner. If that account lacks "Add page"
  rights in the target space you get a 403 — that's a permissions problem in
  Confluence, not something to retry.
