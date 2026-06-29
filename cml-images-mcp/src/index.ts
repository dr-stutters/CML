#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { CmlClient } from "./cml.js";

const cfg = {
  baseUrl: process.env.CML_BASE_URL ?? "https://198.18.128.10",
  username: process.env.CML_USERNAME ?? "admin",
  password: process.env.CML_PASSWORD ?? "",
  verifyTls: /^(1|true|yes)$/i.test(process.env.CML_VERIFY_TLS ?? ""),
};

if (!cfg.password) {
  // Surfaced via stderr so it shows up in MCP client logs without breaking the protocol on stdout.
  process.stderr.write(
    "[cml-images-mcp] WARNING: CML_PASSWORD is not set; authentication will fail.\n"
  );
}

const cml = new CmlClient(cfg);

const server = new McpServer({
  name: "cml-images",
  version: "0.1.0",
});

const ok = (data: unknown) => ({
  content: [
    { type: "text" as const, text: typeof data === "string" ? data : JSON.stringify(data, null, 2) },
  ],
});
const fail = (e: unknown) => ({
  content: [{ type: "text" as const, text: `Error: ${e instanceof Error ? e.message : String(e)}` }],
  isError: true,
});

// ---- Read / discovery tools ---------------------------------------------

server.tool(
  "cml_list_node_definitions",
  "List available node definitions (id + label) so you know valid node_definition_id values for image definitions.",
  {},
  async () => {
    try {
      return ok(await cml.request("/simplified_node_definitions"));
    } catch (e) {
      return fail(e);
    }
  }
);

server.tool(
  "cml_list_image_definitions",
  "List all image definitions currently registered on the CML controller.",
  {},
  async () => {
    try {
      return ok(await cml.request("/image_definitions"));
    } catch (e) {
      return fail(e);
    }
  }
);

server.tool(
  "cml_list_uploaded_images",
  "List disk image files present in the CML image drop folder (files available to reference as disk_image).",
  {},
  async () => {
    try {
      return ok(await cml.request("/list_image_definition_drop_folder"));
    } catch (e) {
      return fail(e);
    }
  }
);

// ---- Upload --------------------------------------------------------------

server.tool(
  "cml_upload_image",
  "Upload a disk image to the CML drop folder. Source may be a local filesystem path (on the machine running this MCP server) OR an http(s) URL, which is streamed to CML. Large multi-GB images are streamed, not buffered through the model.",
  {
    source: z.string().describe("Local file path or http(s):// URL of the disk image (e.g. .qcow2)"),
    filename: z
      .string()
      .optional()
      .describe("Filename to register on the controller. Defaults to the source basename."),
  },
  async ({ source, filename }) => {
    try {
      return ok(await cml.uploadImage(source, filename));
    } catch (e) {
      return fail(e);
    }
  }
);

// ---- Create / delete image definitions -----------------------------------

server.tool(
  "cml_create_image_definition",
  "Create an image definition referencing an already-uploaded disk image. Run cml_list_uploaded_images to find disk_image filenames and cml_list_node_definitions for valid node_definition_id values.",
  {
    id: z.string().describe("Unique identifier for the image definition, e.g. 'ftd-7.4.0'."),
    node_definition_id: z.string().describe("Parent node definition id, e.g. 'ftdv', 'fmcv', 'asav'."),
    label: z.string().describe("Human-readable label shown in the CML UI."),
    disk_image: z
      .string()
      .describe("Filename of the uploaded disk image (from cml_list_uploaded_images)."),
    efi_boot: z.boolean().optional().describe("Whether to boot via EFI. Default false."),
    read_only: z.boolean().optional().describe("Mark the image definition read-only."),
    extra: z
      .record(z.any())
      .optional()
      .describe("Additional ImageDefinition fields to merge (e.g. ram, cpus, disk_subfolder)."),
  },
  async ({ id, node_definition_id, label, disk_image, efi_boot, read_only, extra }) => {
    try {
      const body: Record<string, unknown> = {
        id,
        node_definition_id,
        label,
        disk_image,
        ...(efi_boot !== undefined ? { efi_boot } : {}),
        ...(read_only !== undefined ? { read_only } : {}),
        ...(extra ?? {}),
      };
      return ok(await cml.request("/image_definitions", { method: "POST", body }));
    } catch (e) {
      return fail(e);
    }
  }
);

server.tool(
  "cml_delete_image_definition",
  "Delete an image definition by its id.",
  {
    def_id: z.string().describe("The image definition id to delete."),
  },
  async ({ def_id }) => {
    try {
      return ok(
        (await cml.request(`/image_definitions/${encodeURIComponent(def_id)}`, {
          method: "DELETE",
        })) ?? `Deleted image definition '${def_id}'.`
      );
    } catch (e) {
      return fail(e);
    }
  }
);

server.tool(
  "cml_delete_uploaded_image",
  "Delete an uploaded disk image file from the CML drop folder by filename.",
  {
    filename: z.string().describe("The uploaded image filename to delete."),
  },
  async ({ filename }) => {
    try {
      return ok(
        (await cml.request(`/images/manage/${encodeURIComponent(filename)}`, {
          method: "DELETE",
        })) ?? `Deleted uploaded image '${filename}'.`
      );
    } catch (e) {
      return fail(e);
    }
  }
);

// ---- Node definitions ----------------------------------------------------

server.tool(
  "cml_create_node_definition",
  "Create a new node definition from a full NodeDefinition object (JSON). Use cml_list_node_definitions to inspect existing ones first. Most workflows only need image definitions against built-in node definitions; use this only for genuinely custom platforms.",
  {
    definition: z
      .record(z.any())
      .describe("The full NodeDefinition object (see /api/v0/node_definition_schema)."),
  },
  async ({ definition }) => {
    try {
      return ok(await cml.request("/node_definitions", { method: "POST", body: definition }));
    } catch (e) {
      return fail(e);
    }
  }
);

// ---- Convenience: upload + create in one step ----------------------------

server.tool(
  "cml_install_image",
  "One-shot install: upload a disk image then create an image definition that references it. Combines cml_upload_image + cml_create_image_definition.",
  {
    source: z.string().describe("Local file path or http(s):// URL of the disk image."),
    filename: z.string().optional().describe("Uploaded filename. Defaults to source basename."),
    id: z.string().describe("Unique image definition id."),
    node_definition_id: z.string().describe("Parent node definition id (e.g. 'ftdv', 'fmcv')."),
    label: z.string().describe("Human-readable label."),
    efi_boot: z.boolean().optional().describe("Boot via EFI. Default false."),
  },
  async ({ source, filename, id, node_definition_id, label, efi_boot }) => {
    try {
      const upload = (await cml.uploadImage(source, filename)) as { uploaded_as: string };
      const body: Record<string, unknown> = {
        id,
        node_definition_id,
        label,
        disk_image: upload.uploaded_as,
        ...(efi_boot !== undefined ? { efi_boot } : {}),
      };
      const def = await cml.request("/image_definitions", { method: "POST", body });
      return ok({ upload, image_definition: def });
    } catch (e) {
      return fail(e);
    }
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(`[cml-images-mcp] connected; target=${cfg.baseUrl} user=${cfg.username}\n`);
}

main().catch((e) => {
  process.stderr.write(`[cml-images-mcp] fatal: ${e instanceof Error ? e.stack : String(e)}\n`);
  process.exit(1);
});
