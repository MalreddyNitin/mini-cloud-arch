import { ApiError, type PresignedUpload } from "../api/client";

export const MAX_UPLOAD_BYTES = (() => {
  const configured = Number(import.meta.env.VITE_MAX_UPLOAD_BYTES);
  return Number.isFinite(configured) && configured > 0
    ? configured
    : 10 * 1024 * 1024;
})();

export const ALLOWED_UPLOAD_TYPES = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
  "text/plain",
  "text/csv",
  "application/json",
  "application/zip",
] as const;

export const UPLOAD_ACCEPT = ALLOWED_UPLOAD_TYPES.join(",");

export function formatBytes(bytes: number): string {
  if (bytes === 0) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / 1024 ** index;
  return `${value >= 10 || index === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[index]}`;
}

export function validateUploadFile(file: File): string | null {
  if (file.size === 0) return "Choose a file that is not empty.";
  if (file.size > MAX_UPLOAD_BYTES) {
    return `This file is ${formatBytes(file.size)}. The maximum is ${formatBytes(MAX_UPLOAD_BYTES)}.`;
  }
  if (!ALLOWED_UPLOAD_TYPES.includes(file.type as (typeof ALLOWED_UPLOAD_TYPES)[number])) {
    return "That file type is not supported. Choose an image, PDF, text, CSV, JSON, or ZIP file.";
  }
  return null;
}

export function uploadDirectToR2(
  presign: PresignedUpload,
  file: File,
  onProgress: (percentage: number) => void,
  signal?: AbortSignal,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open(presign.method || "PUT", presign.upload_url);
    request.withCredentials = false;

    const headers = new Headers(presign.headers);
    if (!headers.has("Content-Type")) headers.set("Content-Type", file.type);
    headers.forEach((value, key) => request.setRequestHeader(key, value));

    const handleAbort = () => request.abort();
    signal?.addEventListener("abort", handleAbort, { once: true });

    const cleanUp = () => signal?.removeEventListener("abort", handleAbort);

    request.upload.addEventListener("progress", (event) => {
      if (event.lengthComputable && event.total > 0) {
        onProgress(Math.min(100, Math.round((event.loaded / event.total) * 100)));
      }
    });

    request.addEventListener("load", () => {
      cleanUp();
      if (request.status >= 200 && request.status < 300) {
        onProgress(100);
        resolve();
      } else {
        reject(
          new ApiError(
            `Object storage rejected the upload (${request.status || "unknown status"}).`,
            request.status,
            "upload_rejected",
          ),
        );
      }
    });
    request.addEventListener("error", () => {
      cleanUp();
      reject(
        new ApiError(
          "The direct upload failed. Check the R2 CORS policy and try again.",
          0,
          "upload_network_error",
        ),
      );
    });
    request.addEventListener("abort", () => {
      cleanUp();
      reject(new DOMException("The upload was cancelled.", "AbortError"));
    });

    if (signal?.aborted) {
      request.abort();
      return;
    }
    request.send(file);
  });
}
