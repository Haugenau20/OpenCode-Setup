---
name: mfiles-fetch
description: "Fetches documents and objects from the internal M-Files document management server using the M-Files MCP tools. Use this skill whenever the user wants to look up, fetch, find, search, or browse M-Files documents or objects — even if they don't say 'M-Files' explicitly. Trigger phrases include but are not limited to: 'find that document in M-Files', 'search M-Files for X', 'get object 12345', 'what object types are there', 'show me the properties of that file', 'download that attachment from M-Files'. Always use this skill for document-management / DMS lookups distinct from Jira issues, Git source, or Confluence wiki pages."
---

# M-Files Fetch Skill

Fetches documents and objects from the internal M-Files server using the
available MCP tools, and presents them clearly in the conversation as context
for investigation, planning, or coding tasks.

---

## Available MCP Tools

| Tool                          | What it does                                              |
|--------------------------------|-------------------------------------------------------------|
| `mfiles_list_object_types`     | List object types (Document, Customer, …) with numeric IDs  |
| `mfiles_list_classes`          | List classes and the object type each belongs to            |
| `mfiles_search_objects`        | Free-text search, optionally scoped to an object type       |
| `mfiles_get_object`            | Fetch an object's latest version, properties, and file list |
| `mfiles_get_object_properties` | Fetch just an object's property values                      |
| `mfiles_get_file_content`      | Download a specific file attached to an object               |

---

## Workflows

### Search for a document/object

1. If the object type is unknown, call `mfiles_list_object_types` first to
   learn the relevant type id (skip this if the user already gave one, or if
   an unscoped search is good enough).
2. Call `mfiles_search_objects` with the user's query (and `objectType` if
   scoped).
3. Display the results in full.
4. Offer to fetch full details on any specific hit: *"Would you like me to
   fetch the full details of any of these?"*

---

### Fetch a specific object

When the user gives (or a search result surfaces) an object type + object id:

1. Call `mfiles_get_object` with `objectType` and `objectId`
2. Display the full result, including its property list and any attached
   files
3. If the user wants a particular file's contents, call
   `mfiles_get_file_content` with the `fileId` shown in the object's file list

---

### Browse structure

If the user asks what object types or classes exist (e.g. "what kinds of
documents are there"), call `mfiles_list_object_types` and/or
`mfiles_list_classes` and display the results directly.

---

## Rules

- Never suggest writing to M-Files (creating, editing, or checking in
  objects/files) — this skill is read only
- Never truncate or summarize object properties or file contents — display
  them in full
- Do not ask for confirmation before fetching — fetch, then report back
- If a search returns no results, suggest a broader query or dropping the
  `objectType` filter rather than giving up
- Use `mfiles_list_object_types` first whenever an object type id is needed
  but unknown — don't guess IDs
