# cml-images-mcp

An MCP server for managing **Cisco Modeling Labs (CML 2.10)** image and node
definitions — the capability missing from Cisco's built-in CML MCP. It wraps the
CML `/api/v0` REST API to let an agent **upload disk images** and **create/delete
image and node definitions**.

## Tools

| Tool | Purpose |
|------|---------|
| `cml_list_node_definitions` | List node definitions (valid `node_definition_id` values) |
| `cml_list_image_definitions` | List registered image definitions |
| `cml_list_uploaded_images` | List files in the image drop folder |
| `cml_upload_image` | Upload a disk image from a **local path or URL** (streamed) |
| `cml_create_image_definition` | Create an image definition for an uploaded disk image |
| `cml_delete_image_definition` | Delete an image definition |
| `cml_delete_uploaded_image` | Delete an uploaded disk image file |
| `cml_create_node_definition` | Create a custom node definition (full JSON) |
| `cml_install_image` | One-shot: upload **+** create image definition |

## Configuration (environment)

| Var | Default | Notes |
|-----|---------|-------|
| `CML_BASE_URL` | `https://your-cml-host` | Controller base URL (no `/api/v0`) |
| `CML_USERNAME` | `admin` | Must be a CML **admin** for definition management |
| `CML_PASSWORD` | _(empty)_ | Required |
| `CML_VERIFY_TLS` | `false` | Set `true` only if CML has a trusted cert |

## Build & run

```bash
npm install
npm run build      # -> dist/
CML_PASSWORD='changeme' node dist/index.js   # stdio MCP server
```

## Register with Claude Code

Add to the `mcpServers` block in `~/.claude.json` (under your project, alongside
the existing `Cisco_Modeling_Labs_CML` server). Unlike the built-in CML MCP (a
remote server via `mcp-remote`), this one runs **locally over stdio** so it can
stream large local image files straight to the controller:

```json
"CML_Images": {
  "command": "node",
  "args": ["/home/reptar/Cisco/MCP/CML-Images/dist/index.js"],
  "env": {
    "CML_BASE_URL": "https://your-cml-host",
    "CML_USERNAME": "admin",
    "CML_PASSWORD": "changeme",
    "CML_VERIFY_TLS": "false"
  }
}
```

Restart Claude Code (or run `/mcp`) to connect.

## Typical workflow

```
cml_list_node_definitions          # find the parent, e.g. "ftdv"
cml_install_image                  # upload + register in one call:
  source = /home/reptar/images/ftdv-7.4.0.qcow2
  id = ftdv-7.4.0
  node_definition_id = ftdv
  label = "FTDv 7.4.0"
cml_list_image_definitions         # verify it appears
```

## Notes
- Large images are **streamed** (local files via a read stream with `Content-Length`,
  URLs piped from the upstream response) — bytes never pass through the model.
- Image/node definition management requires admin privileges.
- Built and tested against **CML 2.10.0**.
