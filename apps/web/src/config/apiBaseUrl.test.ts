import { DEVELOPMENT_API_BASE_URL, resolveApiBaseUrl } from "./apiBaseUrl";

describe("API base URL configuration", () => {
  it("uses the local Cloud Run-compatible port only in development", () => {
    expect(resolveApiBaseUrl(undefined, { isDevelopment: true })).toBe(DEVELOPMENT_API_BASE_URL);
    expect(DEVELOPMENT_API_BASE_URL).toBe("http://localhost:8080");
  });

  it("requires an explicit API URL in production", () => {
    expect(() => resolveApiBaseUrl(undefined, { isDevelopment: false })).toThrow(/required in production/i);
    expect(() => resolveApiBaseUrl("   ", { isDevelopment: false })).toThrow(/required in production/i);
  });

  it("requires an absolute HTTPS URL in production", () => {
    expect(() => resolveApiBaseUrl("/api", { isDevelopment: false })).toThrow(/absolute URL/i);
    expect(() => resolveApiBaseUrl("http://api.example.test", { isDevelopment: false })).toThrow(/HTTPS/i);
    expect(() => resolveApiBaseUrl("ftp://api.example.test", { isDevelopment: false })).toThrow(/HTTPS/i);
  });

  it("rejects credentials and URL decorations", () => {
    expect(() => resolveApiBaseUrl("https://user:secret@api.example.test", { isDevelopment: false })).toThrow(/credentials/i);
    expect(() => resolveApiBaseUrl("https://api.example.test?token=nope", { isDevelopment: false })).toThrow(/query string/i);
    expect(() => resolveApiBaseUrl("https://api.example.test/#fragment", { isDevelopment: false })).toThrow(/fragment/i);
  });

  it("normalizes a valid HTTPS origin and optional base path", () => {
    expect(resolveApiBaseUrl(" https://api.example.test/v1/// ", { isDevelopment: false })).toBe(
      "https://api.example.test/v1",
    );
  });
});
