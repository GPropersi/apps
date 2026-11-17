import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// Build output lands in the Go embed directory. The dev proxy targets `go run -tags dev ./cmd/server` on :8080.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "../internal/app/static",
    emptyOutDir: true,
    // The CSP is default-src 'self' (no data: sources), so fonts must stay real files, never inlined.
    assetsInlineLimit: 0,
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
    // vitest blanks CSS imports by default; styles.test.ts reads styles.css?raw to check the colour tokens.
    css: { include: /styles\.css/ },
    restoreMocks: true,
    unstubEnvs: true,
  },
});
