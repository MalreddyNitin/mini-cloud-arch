import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { api, friendlyError, type Item } from "../api/client";
import { Alert } from "../components/Alert";
import { ItemsIcon, PencilIcon, PlusIcon, RefreshIcon, TrashIcon } from "../components/Icons";
import { Spinner } from "../components/Spinner";
import { formatDate } from "../utils/format";

const PAGE_SIZE = 20;

interface ItemRowProps {
  item: Item;
  onSave: (id: string, name: string) => Promise<void>;
  onDelete: (id: string) => Promise<void>;
}

function ItemRow({ item, onSave, onDelete }: ItemRowProps) {
  const [editing, setEditing] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [draft, setDraft] = useState(item.name);
  const [busy, setBusy] = useState(false);

  const save = async (event: FormEvent) => {
    event.preventDefault();
    const nextName = draft.trim();
    if (!nextName || nextName === item.name) {
      setDraft(item.name);
      setEditing(false);
      return;
    }
    setBusy(true);
    try {
      await onSave(item.id, nextName);
      setEditing(false);
    } catch {
      // The parent keeps the row in edit mode and renders the actionable API error.
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    setBusy(true);
    try {
      await onDelete(item.id);
    } catch {
      // The parent keeps the confirmation visible and renders the API error.
    } finally {
      setBusy(false);
    }
  };

  return (
    <li className="item-row">
      <div className="item-row__marker" aria-hidden="true">
        {item.name.slice(0, 1).toUpperCase()}
      </div>
      <div className="item-row__body">
        {editing ? (
          <form className="inline-edit" onSubmit={(event) => void save(event)}>
            <label className="sr-only" htmlFor={`edit-${item.id}`}>Edit item name</label>
            <input
              id={`edit-${item.id}`}
              value={draft}
              maxLength={120}
              onChange={(event) => setDraft(event.target.value)}
              autoFocus
              disabled={busy}
            />
            <button className="button button--small button--primary" type="submit" disabled={busy || !draft.trim()}>
              {busy ? <Spinner label="Saving item" /> : null}
              Save
            </button>
            <button
              className="button button--small button--ghost"
              type="button"
              disabled={busy}
              onClick={() => {
                setDraft(item.name);
                setEditing(false);
              }}
            >
              Cancel
            </button>
          </form>
        ) : (
          <>
            <strong>{item.name}</strong>
            <span>Created {formatDate(item.created_at)}</span>
          </>
        )}
      </div>

      {!editing ? (
        <div className="item-row__actions">
          {confirmingDelete ? (
            <div className="delete-confirm" role="group" aria-label={`Confirm deletion of ${item.name}`}>
              <span>Delete?</span>
              <button className="button button--small button--danger" type="button" onClick={() => void remove()} disabled={busy}>
                {busy ? <Spinner label="Deleting item" /> : null}
                Yes
              </button>
              <button className="button button--small button--ghost" type="button" onClick={() => setConfirmingDelete(false)} disabled={busy}>
                No
              </button>
            </div>
          ) : (
            <>
              <button className="icon-button" type="button" onClick={() => setEditing(true)} aria-label={`Edit ${item.name}`}>
                <PencilIcon />
              </button>
              <button className="icon-button icon-button--danger" type="button" onClick={() => setConfirmingDelete(true)} aria-label={`Delete ${item.name}`}>
                <TrashIcon />
              </button>
            </>
          )}
        </div>
      ) : null}
    </li>
  );
}

export function ItemsPage() {
  const [items, setItems] = useState<Item[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const activeRequest = useRef<AbortController | null>(null);

  const load = useCallback(async (append = false) => {
    activeRequest.current?.abort();
    const controller = new AbortController();
    activeRequest.current = controller;
    if (append) {
      setLoadingMore(true);
    } else {
      setLoading(true);
    }
    setError(null);
    try {
      const offset = append ? items.length : 0;
      const page = await api.listItems(PAGE_SIZE, offset, controller.signal);
      setItems((current) => append ? [...current, ...page.items] : page.items);
      setTotal(page.total);
    } catch (requestError) {
      if (!(requestError instanceof DOMException && requestError.name === "AbortError")) {
        setError(friendlyError(requestError, "Items could not be loaded."));
      }
    } finally {
      if (!controller.signal.aborted) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [items.length]);

  useEffect(() => {
    void load(false);
    return () => activeRequest.current?.abort();
    // Only run the initial request on mount; later pagination uses the current item count.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const create = async (event: FormEvent) => {
    event.preventDefault();
    const nextName = name.trim();
    if (!nextName) return;
    setCreating(true);
    setError(null);
    try {
      const created = await api.createItem(nextName);
      setItems((current) => [created, ...current]);
      setTotal((current) => current + 1);
      setName("");
    } catch (requestError) {
      setError(friendlyError(requestError, "The item could not be created."));
    } finally {
      setCreating(false);
    }
  };

  const update = async (id: string, nextName: string) => {
    setError(null);
    try {
      const updated = await api.updateItem(id, nextName);
      setItems((current) => current.map((item) => item.id === id ? updated : item));
    } catch (requestError) {
      setError(friendlyError(requestError, "The item could not be updated."));
      throw requestError;
    }
  };

  const remove = async (id: string) => {
    setError(null);
    try {
      await api.deleteItem(id);
      setItems((current) => current.filter((item) => item.id !== id));
      setTotal((current) => Math.max(0, current - 1));
    } catch (requestError) {
      setError(friendlyError(requestError, "The item could not be deleted."));
      throw requestError;
    }
  };

  return (
    <div className="page">
      <section className="page-heading page-heading--split">
        <div>
          <span className="eyebrow">Relational data</span>
          <h1>Items</h1>
          <p>A compact CRUD slice backed by Neon Postgres through the Cloud Run API.</p>
        </div>
        <button className="button button--secondary" type="button" onClick={() => void load(false)} disabled={loading}>
          {loading ? <Spinner label="Refreshing items" /> : <RefreshIcon />}
          Refresh
        </button>
      </section>

      <Alert tone="info">
        Public deployments are read-only by default. Create, edit, and delete work locally, or after the operator adds real user authentication.
      </Alert>

      {error ? <Alert onDismiss={() => setError(null)}>{error}</Alert> : null}

      <section className="create-card" aria-labelledby="create-item-title">
        <div>
          <span className="create-card__icon"><PlusIcon /></span>
          <div>
            <h2 id="create-item-title">Create an item</h2>
            <p>Names are trimmed and limited to 120 characters.</p>
          </div>
        </div>
        <form className="create-form" onSubmit={(event) => void create(event)}>
          <label className="sr-only" htmlFor="item-name">Item name</label>
          <input
            id="item-name"
            type="text"
            placeholder="e.g. First production-shaped record"
            value={name}
            maxLength={120}
            onChange={(event) => setName(event.target.value)}
            disabled={creating}
          />
          <button className="button button--primary" type="submit" disabled={creating || !name.trim()}>
            {creating ? <Spinner label="Creating item" /> : <PlusIcon />}
            {creating ? "Creating…" : "Add item"}
          </button>
        </form>
      </section>

      <section className="list-card" aria-labelledby="item-list-title" aria-busy={loading}>
        <div className="list-card__header">
          <div>
            <span className="list-card__icon"><ItemsIcon /></span>
            <div>
              <h2 id="item-list-title">Saved items</h2>
              <p>{loading ? "Loading records…" : `${total} ${total === 1 ? "record" : "records"}`}</p>
            </div>
          </div>
          <span className="database-label">Neon Postgres</span>
        </div>

        {loading ? (
          <div className="skeleton-list" aria-label="Loading items">
            {[0, 1, 2].map((index) => <span key={index} />)}
          </div>
        ) : items.length === 0 ? (
          <div className="empty-state">
            <span><ItemsIcon /></span>
            <h3>No items yet</h3>
            <p>Create the first record above to verify the database round trip.</p>
          </div>
        ) : (
          <ul className="item-list">
            {items.map((item) => (
              <ItemRow key={item.id} item={item} onSave={update} onDelete={remove} />
            ))}
          </ul>
        )}

        {!loading && items.length < total ? (
          <div className="load-more">
            <button className="button button--secondary" type="button" onClick={() => void load(true)} disabled={loadingMore}>
              {loadingMore ? <Spinner label="Loading more items" /> : null}
              {loadingMore ? "Loading…" : `Load more (${total - items.length} remaining)`}
            </button>
          </div>
        ) : null}
      </section>
    </div>
  );
}
