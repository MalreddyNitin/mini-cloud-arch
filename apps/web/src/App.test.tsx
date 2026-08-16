import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { App } from "./App";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("App", () => {
  it("keeps R2 unverified when the API exposes no storage probe", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ status: "ok", service: "zero-cloud-api" }))
      .mockResolvedValueOnce(jsonResponse({ status: "ready", checks: { database: true } }));
    vi.stubGlobal("fetch", fetchMock);

    render(
      <MemoryRouter
        initialEntries={["/overview"]}
        future={{ v7_startTransition: true, v7_relativeSplatPath: true }}
      >
        <App />
      </MemoryRouter>,
    );

    expect(await screen.findByText("Visible checks healthy; R2 remains unverified")).toBeInTheDocument();
    expect(screen.getByText("Not verified")).toBeInTheDocument();
    expect(screen.queryByText("All visible checks operational")).not.toBeInTheDocument();
  });

  it("renders a friendly fallback for an unknown client-side route", () => {
    render(
      <MemoryRouter
        initialEntries={["/missing-route"]}
        future={{ v7_startTransition: true, v7_relativeSplatPath: true }}
      >
        <App />
      </MemoryRouter>,
    );

    expect(screen.getByRole("heading", { name: /this path drifted/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /return to overview/i })).toHaveAttribute("href", "/overview");
  });

  it("loads items and surfaces the production read-only response", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        jsonResponse({
          items: [{ id: "item-1", name: "Existing record", created_at: "2026-08-15T12:00:00Z" }],
          total: 1,
          limit: 20,
          offset: 0,
        }),
      )
      .mockResolvedValueOnce(jsonResponse({ detail: "Forbidden" }, 403));
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    render(
      <MemoryRouter
        initialEntries={["/items"]}
        future={{ v7_startTransition: true, v7_relativeSplatPath: true }}
      >
        <App />
      </MemoryRouter>,
    );

    expect(await screen.findByText("Existing record")).toBeInTheDocument();
    await user.type(screen.getByLabelText("Item name"), "Protected record");
    await user.click(screen.getByRole("button", { name: "Add item" }));

    expect(await screen.findByText(/^This deployment is read-only/)).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
