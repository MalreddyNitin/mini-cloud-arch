import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";
import { loadEnv } from "vite";
import { resolveApiBaseUrl } from "./src/config/apiBaseUrl";

export default defineConfig(({ mode }) => {
  if (mode === "production") {
    const environment = loadEnv(mode, process.cwd(), "VITE_");
    resolveApiBaseUrl(environment.VITE_API_BASE_URL, { isDevelopment: false });
  }

  return {
    plugins: [react()],
    server: {
      host: "127.0.0.1",
      port: 5173,
      strictPort: true,
    },
    preview: {
      host: "127.0.0.1",
      port: 4173,
      strictPort: true,
    },
    build: {
      target: "es2022",
      sourcemap: false,
      assetsInlineLimit: 4096,
      rollupOptions: {
        output: {
          manualChunks: {
            vendor: ["react", "react-dom", "react-router-dom"],
          },
        },
      },
    },
    test: {
      environment: "jsdom",
      globals: true,
      setupFiles: ["./src/test/setup.ts"],
      css: true,
    },
  };
});
