import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// Build output lands in the Go embed directory. The dev proxy targets `go run -tags dev ./cmd/server` on :8080.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "../internal/app/static",
    emptyOutDir: true,
  },
  server: {
    proxy: {
      "/api": "http://localhost:8080",
      "/healthz": "http://localhost:8080",
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test-setup.ts"],
    restoreMocks: true,
    unstubEnvs: true,
  },
});
