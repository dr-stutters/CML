import { createReadStream, statSync } from "node:fs";
import { basename } from "node:path";
import { Readable } from "node:stream";
import { Agent, setGlobalDispatcher } from "undici";

export interface CmlConfig {
  baseUrl: string; // e.g. https://198.18.128.10
  username: string;
  password: string;
  verifyTls: boolean;
}

/**
 * Minimal client for the CML 2.10 REST API (/api/v0) covering image and node
 * definition management. Authenticates with username/password to obtain a
 * bearer token, then reuses it (re-authenticating once on a 401).
 */
export class CmlClient {
  private token: string | null = null;

  constructor(private cfg: CmlConfig) {
    if (!cfg.verifyTls) {
      // CML ships a self-signed cert by default.
      setGlobalDispatcher(new Agent({ connect: { rejectUnauthorized: false } }));
    }
  }

  private api(path: string): string {
    const base = this.cfg.baseUrl.replace(/\/+$/, "");
    return `${base}/api/v0${path.startsWith("/") ? path : "/" + path}`;
  }

  private async authenticate(): Promise<string> {
    const res = await fetch(this.api("/authenticate"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        username: this.cfg.username,
        password: this.cfg.password,
      }),
    });
    if (!res.ok) {
      throw new Error(
        `Authentication to CML failed: ${res.status} ${res.statusText} — ${await safeText(res)}`
      );
    }
    // CML returns the bearer token as a bare JSON string.
    const token = (await res.json()) as string;
    this.token = token;
    return token;
  }

  private async authHeader(): Promise<string> {
    if (!this.token) await this.authenticate();
    return `Bearer ${this.token}`;
  }

  /** JSON request helper with one automatic re-auth on 401. */
  async request<T = unknown>(
    path: string,
    init: { method?: string; body?: unknown } = {}
  ): Promise<T> {
    const doFetch = async () => {
      const headers: Record<string, string> = {
        Authorization: await this.authHeader(),
        Accept: "application/json",
      };
      let body: string | undefined;
      if (init.body !== undefined) {
        headers["Content-Type"] = "application/json";
        body = JSON.stringify(init.body);
      }
      return fetch(this.api(path), { method: init.method ?? "GET", headers, body });
    };

    let res = await doFetch();
    if (res.status === 401) {
      this.token = null;
      res = await doFetch();
    }
    if (!res.ok) {
      throw new Error(
        `CML ${init.method ?? "GET"} ${path} failed: ${res.status} ${res.statusText} — ${await safeText(res)}`
      );
    }
    const text = await res.text();
    return (text ? JSON.parse(text) : null) as T;
  }

  /**
   * Upload a disk / reference image to the CML drop folder.
   *
   * @param source   Local filesystem path OR an http(s) URL to fetch and stream.
   * @param filename Name to register on the controller (X-Original-File-Name).
   *                 Defaults to the basename of the source.
   */
  async uploadImage(source: string, filename?: string): Promise<unknown> {
    const isUrl = /^https?:\/\//i.test(source);
    const name = filename ?? basename(new URL(isUrl ? source : `file:///${source}`).pathname);

    let body: BodyInit;
    let contentLength: string | undefined;

    if (isUrl) {
      const upstream = await fetch(source);
      if (!upstream.ok || !upstream.body) {
        throw new Error(`Failed to fetch source URL ${source}: ${upstream.status} ${upstream.statusText}`);
      }
      const len = upstream.headers.get("content-length");
      if (len) contentLength = len;
      body = upstream.body as unknown as BodyInit;
    } else {
      const stat = statSync(source); // throws clearly if the path is wrong
      contentLength = String(stat.size);
      body = Readable.toWeb(createReadStream(source)) as unknown as BodyInit;
    }

    const headers: Record<string, string> = {
      Authorization: await this.authHeader(),
      "Content-Type": "application/octet-stream",
      "X-Original-File-Name": name,
      "X-File-Name": name,
    };
    if (contentLength) headers["Content-Length"] = contentLength;

    const res = await fetch(this.api("/images/upload"), {
      method: "POST",
      headers,
      body,
      // Required by Node/undici when streaming a request body.
      duplex: "half",
    } as RequestInit & { duplex: "half" });

    if (!res.ok) {
      throw new Error(
        `CML image upload failed: ${res.status} ${res.statusText} — ${await safeText(res)}`
      );
    }
    const text = await res.text();
    return { uploaded_as: name, response: text ? tryJson(text) : "OK" };
  }
}

async function safeText(res: Response): Promise<string> {
  try {
    return (await res.text()).slice(0, 500);
  } catch {
    return "<no body>";
  }
}

function tryJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}
