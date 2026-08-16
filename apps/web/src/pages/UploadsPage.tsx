import { useEffect, useRef, useState, type ChangeEvent, type DragEvent } from "react";
import { api, friendlyError } from "../api/client";
import { Alert } from "../components/Alert";
import { CheckIcon, CloseIcon, FileIcon, ShieldIcon, StorageIcon, UploadIcon } from "../components/Icons";
import { Spinner } from "../components/Spinner";
import {
  formatBytes,
  MAX_UPLOAD_BYTES,
  UPLOAD_ACCEPT,
  uploadDirectToR2,
  validateUploadFile,
} from "../utils/upload";

type UploadPhase = "idle" | "signing" | "uploading" | "complete";

export function UploadsPage() {
  const [file, setFile] = useState<File | null>(null);
  const [dragging, setDragging] = useState(false);
  const [phase, setPhase] = useState<UploadPhase>("idle");
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [uploadedKey, setUploadedKey] = useState<string | null>(null);
  const activeUpload = useRef<AbortController | null>(null);

  useEffect(() => () => activeUpload.current?.abort(), []);

  const chooseFile = (nextFile: File | undefined) => {
    setError(null);
    setUploadedKey(null);
    setProgress(0);
    setPhase("idle");
    if (!nextFile) {
      setFile(null);
      return;
    }
    const validationError = validateUploadFile(nextFile);
    if (validationError) {
      setFile(null);
      setError(validationError);
      return;
    }
    setFile(nextFile);
  };

  const onInputChange = (event: ChangeEvent<HTMLInputElement>) => {
    chooseFile(event.target.files?.[0]);
    event.target.value = "";
  };

  const onDrop = (event: DragEvent<HTMLLabelElement>) => {
    event.preventDefault();
    setDragging(false);
    chooseFile(event.dataTransfer.files?.[0]);
  };

  const upload = async () => {
    if (!file) return;
    const controller = new AbortController();
    activeUpload.current = controller;
    setError(null);
    setUploadedKey(null);
    setProgress(0);
    setPhase("signing");
    try {
      const presign = await api.presignUpload(file);
      if (controller.signal.aborted) return;
      setPhase("uploading");
      await uploadDirectToR2(presign, file, setProgress, controller.signal);
      setUploadedKey(presign.key);
      setPhase("complete");
    } catch (uploadError) {
      setPhase("idle");
      if (uploadError instanceof DOMException && uploadError.name === "AbortError") {
        setError("The upload was cancelled. No application record was created.");
      } else {
        setError(friendlyError(uploadError, "The file could not be uploaded."));
      }
    } finally {
      activeUpload.current = null;
    }
  };

  const cancel = () => activeUpload.current?.abort();
  const busy = phase === "signing" || phase === "uploading";

  return (
    <div className="page">
      <section className="page-heading">
        <span className="eyebrow">Object storage</span>
        <h1>Direct file upload</h1>
        <p>Ask the API for short-lived permission, then send bytes straight from this browser to private R2 storage.</p>
      </section>

      <Alert tone="info">
        Public deployments keep uploads disabled until real user authentication is configured. No shared API secret is accepted or stored here.
      </Alert>

      {error ? <Alert onDismiss={() => setError(null)}>{error}</Alert> : null}
      {phase === "complete" && uploadedKey ? (
        <Alert tone="success" onDismiss={() => setUploadedKey(null)}>
          <strong>Upload complete.</strong> Stored with the server-generated key <code>{uploadedKey}</code>.
        </Alert>
      ) : null}

      <section className="upload-card" aria-labelledby="upload-title">
        <div className="upload-card__heading">
          <span className="upload-card__icon"><StorageIcon /></span>
          <div>
            <h2 id="upload-title">Choose one file</h2>
            <p>Maximum {formatBytes(MAX_UPLOAD_BYTES)} · images, PDF, text, CSV, JSON, or ZIP</p>
          </div>
        </div>

        <label
          className={`dropzone${dragging ? " dropzone--dragging" : ""}${busy ? " dropzone--disabled" : ""}`}
          onDragEnter={() => setDragging(true)}
          onDragLeave={() => setDragging(false)}
          onDragOver={(event) => event.preventDefault()}
          onDrop={onDrop}
        >
          <input type="file" accept={UPLOAD_ACCEPT} onChange={onInputChange} disabled={busy} />
          <span className="dropzone__icon"><UploadIcon /></span>
          <strong>Drop a file here, or <span>browse</span></strong>
          <small>Validation happens before the API is contacted.</small>
        </label>

        {file ? (
          <div className="selected-file">
            <span className="selected-file__icon"><FileIcon /></span>
            <div className="selected-file__details">
              <strong>{file.name}</strong>
              <span>{formatBytes(file.size)} · {file.type}</span>
            </div>
            {busy ? (
              <div className="upload-progress" aria-live="polite">
                <div>
                  <span>{phase === "signing" ? "Requesting permission…" : `Uploading… ${progress}%`}</span>
                  {phase === "uploading" ? <strong>{progress}%</strong> : <Spinner label="Requesting upload permission" />}
                </div>
                <progress
                  className="progress-track"
                  max={100}
                  value={phase === "uploading" ? progress : undefined}
                  aria-label={phase === "signing" ? "Requesting upload permission" : `Upload ${progress}% complete`}
                />
              </div>
            ) : (
              <button className="icon-button" type="button" onClick={() => chooseFile(undefined)} aria-label={`Remove ${file.name}`}>
                <CloseIcon />
              </button>
            )}
          </div>
        ) : null}

        <div className="upload-actions">
          {busy ? (
            <button className="button button--secondary" type="button" onClick={cancel}>Cancel upload</button>
          ) : (
            <button className="button button--primary button--wide" type="button" onClick={() => void upload()} disabled={!file}>
              <UploadIcon />
              Upload directly to R2
            </button>
          )}
        </div>
      </section>

      <section className="safety-grid" aria-label="Upload safety details">
        <article>
          <span><ShieldIcon /></span>
          <div>
            <h2>Short-lived permission</h2>
            <p>The API validates metadata and returns a time-limited, single-object URL. R2 credentials never enter the browser.</p>
          </div>
        </article>
        <article>
          <span><CheckIcon /></span>
          <div>
            <h2>No API byte relay</h2>
            <p>The file body goes directly to R2, conserving Cloud Run runtime and Google network transfer.</p>
          </div>
        </article>
      </section>
    </div>
  );
}
