import { defineConfig } from "vite";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  build: {
    rollupOptions: {
      input: {
        home: resolve(projectRoot, "index.html"),
        login: resolve(projectRoot, "login.html"),
        register: resolve(projectRoot, "register.html"),
        admin: resolve(projectRoot, "admin/dashboard/index.html"),
        owner: resolve(projectRoot, "owner/dashboard/index.html"),
        staff: resolve(projectRoot, "staff/dashboard/index.html"),
        customer: resolve(projectRoot, "customer/dashboard/index.html"),
        business: resolve(projectRoot, "b/index.html"),
        customerBusiness: resolve(projectRoot, "customer/business/index.html"),
        willowBusiness: resolve(projectRoot, "b/willow-and-pine/index.html"),
      },
    },
  },
  plugins: [
    {
      name: "loyalloop-demo-dashboard-routes",
      configureServer(server) {
        server.middlewares.use((request, _response, next) => {
          if (request.url) {
            const separator = request.url.indexOf("?");
            const pathname = separator === -1 ? request.url : request.url.slice(0, separator);
            const query = separator === -1 ? "" : request.url.slice(separator);
            const normalized = pathname.replace(/\/+$/, "") || "/";
            if (normalized === "/staff/dashboard") request.url = `/staff/dashboard/index.html${query}`;
            else if (normalized === "/customer/dashboard") request.url = `/customer/dashboard/index.html${query}`;
            else {
              const businessRoute = normalized.match(/^\/customer\/business\/([a-z0-9-]+)\/?$/i);
              if (businessRoute) request.url = `/customer/business/index.html?slug=${encodeURIComponent(businessRoute[1])}${query ? `&${query.slice(1)}` : ""}`;
            }
          }
          next();
        });
      },
    },
  ],
});
