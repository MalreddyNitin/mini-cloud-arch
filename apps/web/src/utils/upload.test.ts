import {
  ALLOWED_UPLOAD_TYPES,
  formatBytes,
  MAX_UPLOAD_BYTES,
  validateUploadFile,
} from "./upload";

describe("upload validation", () => {
  it("accepts every content type agreed with the API", () => {
    for (const type of ALLOWED_UPLOAD_TYPES) {
      const file = new File(["valid"], `fixture-${type.replace("/", ".")}`, { type });
      expect(validateUploadFile(file)).toBeNull();
    }
  });

  it("rejects empty, oversized, and unsupported files before presigning", () => {
    expect(validateUploadFile(new File([], "empty.txt", { type: "text/plain" }))).toMatch(/not empty/i);

    const oversized = new File(["x"], "large.pdf", { type: "application/pdf" });
    Object.defineProperty(oversized, "size", { value: MAX_UPLOAD_BYTES + 1 });
    expect(validateUploadFile(oversized)).toMatch(/maximum/i);

    expect(validateUploadFile(new File(["x"], "run.exe", { type: "application/x-msdownload" }))).toMatch(/not supported/i);
  });

  it("formats binary sizes for UI messages", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(1024)).toBe("1.0 KB");
    expect(formatBytes(10 * 1024 * 1024)).toBe("10 MB");
  });
});
