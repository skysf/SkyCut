// Vite builds the four static locales; the same Vercel handler serves the local form.
import { defineConfig } from 'vite';
import { resolve } from 'node:path';
import subscribe from './api/subscribe.js';
import {LANGUAGES,PAGES} from './scripts/site-config.mjs';
import {guideRoutes} from './scripts/guide-model.mjs';
const inputs = {root:resolve('index.html'),error:resolve('404.html')};
for (const language of LANGUAGES) for (const page of PAGES) {
  inputs[`${language}-${page || 'home'}`] = resolve(language,page,'index.html');
}
for (const {path} of guideRoutes()) inputs[`guide${path.replace(/\//g,'-')}`] = resolve(path.slice(1),'index.html');
export default defineConfig({
  build:{rollupOptions:{input:inputs},assetsInlineLimit:0},
  server:{port:5173,strictPort:true},
  plugins:[{name:'skycut-local-api',configureServer(server){server.middlewares.use('/api/subscribe',(req,res) => {void subscribe(req,res);});}}]
});
