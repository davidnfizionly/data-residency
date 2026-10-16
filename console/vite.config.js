import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { auditApi } from './server/api.js';

export default defineConfig({
  plugins: [react(), tailwindcss(), auditApi()],
  server: { host: '127.0.0.1', port: 5173 },
});
