import { ApiClient, ApiError, friendlyError } from "./client";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("ApiClient", () => {
  it("normalizes the API base URL and paginates item requests", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({ items: [], total: 0, limit: 20, offset: 40 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const client = new ApiClient("https://api.example.test///");

    await client.listItems(20, 40);

    expect(client.originLabel).toBe("api.example.test");
    expect(fetchMock).toHaveBeenCalledWith(
      "https://api.example.test/api/items?limit=20&offset=40",
      expect.objectContaining({ credentials: "same-origin" }),
    );
  });

  it("sends the exact item update contract", async () => {
    const item = {
      id: "46b53f45-8624-46bf-bf4f-b03210095baf",
      name: "Updated",
      created_at: "2026-08-15T12:00:00Z",
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(item));
    vi.stubGlobal("fetch", fetchMock);
    const client = new ApiClient("https://api.example.test");

    await expect(client.updateItem(item.id, item.name)).resolves.toEqual(item);
    const [, request] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(request.method).toBe("PATCH");
    expect(request.body).toBe(JSON.stringify({ name: "Updated" }));
  });

  it("turns FastAPI validation details into a useful error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        jsonResponse({ detail: [{ loc: ["body", "name"], msg: "Field required" }] }, 422),
      ),
    );
    const client = new ApiClient("https://api.example.test");

    await expect(client.createItem("")).rejects.toMatchObject({
      name: "ApiError",
      status: 422,
      message: "Field required",
    });
  });

  it("explains protected writes without requesting a browser secret", () => {
    expect(friendlyError(new ApiError("Forbidden", 403), "fallback")).toMatch(/read-only/i);
    expect(friendlyError(new ApiError("Unauthorized", 401), "fallback")).toMatch(/real user authentication/i);
  });

  it("requests an upload URL using file metadata only", async () => {
    const presign = {
      upload_url: "https://signed.example.test/object",
      key: "uploads/demo/object.txt",
      method: "PUT" as const,
      headers: { "Content-Type": "text/plain" },
      expires_in: 300,
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(presign));
    vi.stubGlobal("fetch", fetchMock);
    const client = new ApiClient("https://api.example.test");
    const file = new File(["small body"], "note.txt", { type: "text/plain" });

    await expect(client.presignUpload(file)).resolves.toEqual(presign);
    const [, request] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(request.body as string)).toEqual({
      filename: "note.txt",
      content_type: "text/plain",
      size_bytes: 10,
    });
  });
});
