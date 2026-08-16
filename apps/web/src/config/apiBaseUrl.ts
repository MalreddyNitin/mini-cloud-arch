export const DEVELOPMENT_API_BASE_URL = "http://localhost:8080";

interface ResolveApiBaseUrlOptions {
  isDevelopment: boolean;
}

function configurationError(message: string): Error {
  return new Error(`[zero-cloud/web] ${message}`);
}

export function resolveApiBaseUrl(
  configuredValue: string | undefined,
  { isDevelopment }: ResolveApiBaseUrlOptions,
): string {
  const configured = configuredValue?.trim();
  if (!configured) {
    if (isDevelopment) return DEVELOPMENT_API_BASE_URL;
    throw configurationError(
      "VITE_API_BASE_URL is required in production. Set it to the public HTTPS API origin before building or starting the site.",
    );
  }

  let url: URL;
  try {
    url = new URL(configured);
  } catch {
    throw configurationError(
      "VITE_API_BASE_URL must be an absolute URL, such as https://api.example.com.",
    );
  }

  const allowedProtocols = isDevelopment ? ["http:", "https:"] : ["https:"];
  if (!allowedProtocols.includes(url.protocol)) {
    throw configurationError(
      isDevelopment
        ? "VITE_API_BASE_URL must use http:// or https://."
        : "VITE_API_BASE_URL must use HTTPS in production.",
    );
  }
  if (url.username || url.password) {
    throw configurationError("VITE_API_BASE_URL must not contain credentials.");
  }
  if (url.search || url.hash) {
    throw configurationError("VITE_API_BASE_URL must not contain a query string or fragment.");
  }

  const path = url.pathname.replace(/\/+$/, "");
  return `${url.origin}${path}`;
}
