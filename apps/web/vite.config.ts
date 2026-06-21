import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Frontend SPA. Em dev, o caminho /api é encaminhado para a API REST
// (no docker-compose o host é "api"; rodando fora do compose, "localhost").
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    host: true, // expõe na rede para funcionar dentro do container
    proxy: {
      "/api": {
        target: process.env.API_PROXY_TARGET ?? "http://api:8080",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
  },
});
