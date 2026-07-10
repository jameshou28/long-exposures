import { defineConfig, createServer, type Plugin } from "vite";
import { resolve } from "node:path";
import { readFile, writeFile } from "node:fs/promises";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// prerender the React pages to static HTML for seo
function prerender(pages: { html: string; module: string; component: string }[]): Plugin {
  return {
    name: "prerender",
    apply: "build",
    async closeBundle() {
      const server = await createServer({
        configFile: false,
        plugins: [react()],
        server: { middlewareMode: true },
        optimizeDeps: { noDiscovery: true },
        appType: "custom",
        logLevel: "warn",
      });
      try {
        const { renderToString } = await import("react-dom/server");
        const { jsx } = await import("react/jsx-runtime");
        for (const page of pages) {
          const mod = await server.ssrLoadModule(page.module);
          const markup = renderToString(jsx(mod[page.component], {}));
          const file = resolve(import.meta.dirname, "dist", page.html);
          const shell = await readFile(file, "utf8");
          await writeFile(
            file,
            shell.replace('<div id="root"></div>', `<div id="root">${markup}</div>`)
          );
        }
      } finally {
        await server.close();
      }
    },
  };
}

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    prerender([
      { html: "index.html", module: "/src/LandingPage.tsx", component: "LandingPage" },
      { html: "privacy.html", module: "/src/PrivacyPage.tsx", component: "PrivacyPage" },
    ]),
  ],
  build: {
    rollupOptions: {
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        privacy: resolve(import.meta.dirname, "privacy.html"),
      },
    },
  },
});
