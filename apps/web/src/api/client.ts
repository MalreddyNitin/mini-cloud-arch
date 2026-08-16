import { resolveApiBaseUrl } from "../config/apiBaseUrl";

export interface HealthResponse {
  status: string;
  service?: string;
  version?: string;
  environment?: string;
  timestamp?: string;
}

export interface ReadyResponse {
  status: string;
  checks?: Record<string, string | boolean>;
}

export interface Item {
  id: string;
  name: string;
  created_at: string;
}

export interface ItemPage {
  items: Item[];
  total: number;
  limit: number;
  offset: number;
}

export interface PresignedUpload {
  upload_url: string;
  key: string;
  method: "PUT";
  headers: Record<string, string>;
  expires_in: number;
}

interface ApiErrorBody {
  detail?: unknown;
  message?: unknown;
}

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(message: string, status = 0, code = "request_failed") {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

function errorMessageFromBody(body: ApiErrorBody | null, fallback: string): string {
  if (typeof body?.detail === "string") return body.detail;
  if (typeof body?.message === "string") return body.message;

  if (Array.isArray(body?.detail)) {
    const messages = body.detail
      .map((entry: unknown) => {
        if (!entry || typeof entry !== "object") return null;
        const message = (entry as { msg?: unknown }).msg;
        return typeof message === "string" ? message : null;
      })
      .filter((message): message is string => Boolean(message));
    if (messages.length > 0) return messages.join("; ");
  }

  return fallback;
}

async function parseErrorBody(response: Response): Promise<ApiErrorBody | null> {
  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.includes("application/json")) return null;
  try {
    return (await response.json()) as ApiErrorBody;
  } catch {
    return null;
  }
}

export class ApiClient {
  readonly baseUrl: string;

  constructor(
    baseUrl = resolveApiBaseUrl(import.meta.env.VITE_API_BASE_URL, {
      isDevelopment: import.meta.env.DEV,
    }),
  ) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
  }

  get originLabel(): string {
    try {
      return new URL(this.baseUrl).host;
    } catch {
      return this.baseUrl;
    }
  }

  private async request<T>(
    path: string,
    options: RequestInit = {},
  ): Promise<T> {
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body && !headers.has("Content-Type")) {
      headers.set("Content-Type", "application/json");
    }

    let response: Response;
    try {
      response = await fetch(`${this.baseUrl}${path}`, {
        ...options,
        headers,
        credentials: "same-origin",
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") throw error;
      throw new ApiError(
        "Could not reach the API. Check that it is running and that this site is allowed by CORS.",
        0,
        "network_error",
      );
    }

    if (!response.ok) {
      const body = await parseErrorBody(response);
      const fallback = `The API returned ${response.status} ${response.statusText}`.trim();
      throw new ApiError(
        errorMessageFromBody(body, fallback),
        response.status,
        `http_${response.status}`,
      );
    }

    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  health(signal?: AbortSignal): Promise<HealthResponse> {
    return this.request<HealthResponse>("/health", { signal });
  }

  ready(signal?: AbortSignal): Promise<ReadyResponse> {
    return this.request<ReadyResponse>("/ready", { signal });
  }

  listItems(limit = 20, offset = 0, signal?: AbortSignal): Promise<ItemPage> {
    const query = new URLSearchParams({
      limit: String(limit),
      offset: String(offset),
    });
    return this.request<ItemPage>(`/api/items?${query.toString()}`, { signal });
  }

  createItem(name: string): Promise<Item> {
    return this.request<Item>("/api/items", {
      method: "POST",
      body: JSON.stringify({ name }),
    });
  }

  updateItem(id: string, name: string): Promise<Item> {
    return this.request<Item>(`/api/items/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: JSON.stringify({ name }),
    });
  }

  deleteItem(id: string): Promise<void> {
    return this.request<void>(`/api/items/${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
  }

  presignUpload(file: File): Promise<PresignedUpload> {
    return this.request<PresignedUpload>("/api/files/presign-upload", {
      method: "POST",
      body: JSON.stringify({
        filename: file.name,
        content_type: file.type,
        size_bytes: file.size,
      }),
    });
  }
}

export const api = new ApiClient();

export function friendlyError(error: unknown, fallback: string): string {
  if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
    return "This deployment is read-only. Writes are available locally or after the operator configures real user authentication.";
  }
  if (error instanceof ApiError) return error.message;
  if (error instanceof Error && error.name === "AbortError") return "The request was cancelled.";
  return fallback;
}
