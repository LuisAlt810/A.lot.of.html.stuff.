#!/usr/bin/env bash
set -euo pipefail

# fix_monorepo_no_install.sh
# Scaffolds a working monorepo but DOES NOT run npm / npm run dev automatically.
# Puts Prisma inside packages/backend/prisma so backend is self-contained.

PROJECT_DIR="${1:-awesome-monorepo-fixed}"
TIMESTAMP=$(date +%s)
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "Creating project at: $(pwd)"
echo

backup_if_exists() {
  local f="$1"
  if [ -e "$f" ]; then
    local bak="${f}.bak.$TIMESTAMP"
    echo "Backing up existing $f -> $bak"
    mv "$f" "$bak"
  fi
}

# write helper that avoids accidental expansion
safe_cat() {
  local path="$1"; shift
  backup_if_exists "$path"
  cat > "$path" <<'EOF'
'"$@"'
EOF
}

# ---------- Layout ----------
mkdir -p packages/frontend
mkdir -p packages/backend/prisma
mkdir -p infra  # optional
mkdir -p .github/workflows

# ---------- Root files ----------
backup_if_exists README.md
cat > README.md <<'MD'
# Awesome Monorepo (fixed, no automatic npm)

This scaffold creates a working monorepo with:
- packages/frontend (Vite + React + TypeScript + Tailwind)
- packages/backend (Express + TypeScript + WebSocket + Prisma)
- Dockerfiles and docker-compose to run the full stack

**Important:** This script does NOT run `npm install` or any installs. Install manually (instructions in NOTES.txt).
MD

backup_if_exists .gitignore
cat > .gitignore <<'GIT'
node_modules/
packages/*/node_modules/
dist/
.env
.DS_Store
GIT

# Simple Makefile
backup_if_exists Makefile
cat > Makefile <<'MK'
.PHONY: up down build clean

up:
	docker-compose up --build -d

down:
	docker-compose down -v

build:
	docker-compose build

clean:
	rm -rf packages/*/node_modules packages/*/dist
MK

# Root docker-compose (uses relative contexts to packages)
backup_if_exists docker-compose.yml
cat > docker-compose.yml <<'YAML'
version: "3.8"
services:
  db:
    image: postgres:15
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=awesome_db
    volumes:
      - db-data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  backend:
    build:
      context: ./packages/backend
      dockerfile: Dockerfile
    env_file:
      - .env.backend
    depends_on:
      - db
    ports:
      - "4000:4000"
    restart: unless-stopped

  frontend:
    build:
      context: ./packages/frontend
      dockerfile: Dockerfile
    ports:
      - "3000:80"
    restart: unless-stopped

volumes:
  db-data:
YAML

# .env for backend (used by docker-compose)
backup_if_exists .env.backend
cat > .env.backend <<'ENV'
DATABASE_URL="postgresql://postgres:postgres@db:5432/awesome_db?schema=public"
PORT=4000
NODE_ENV=production
ENV

backup_if_exists NOTES.txt
cat > NOTES.txt <<'NOTE'
IMPORTANT - manual steps (read before running anything):

1) Install Node.js (>=18) and npm locally if you plan to run dev mode without Docker.

2) Backend (one-time setup for dev):
   cd packages/backend
   npm install
   npx prisma generate
   # (optional) run seed:
   npx ts-node prisma/seed.ts

   Dev server:
   npm run dev
   Build:
   npm run build
   Start (production):
   npm run start

3) Frontend:
   cd packages/frontend
   npm install
   npm run dev    # runs Vite dev server at 5173
   npm run build  # builds static files for Docker

4) Docker:
   From repo root:
     docker-compose up --build
   This brings up DB, backend (4000), frontend (3000 served by nginx)

Troubleshooting tips:
 - If a command fails, read the error; likely cause is missing npm install.
 - If Prisma errors, ensure DATABASE_URL points to a running Postgres (Docker or local).
 - If a file already existed, it was moved to filename.bak.TIMESTAMP
NOTE

# ---------- Backend (self-contained Prisma) ----------
cd packages/backend

backup_if_exists package.json
cat > package.json <<'PKG'
{
  "name": "awesome-backend",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "ts-node-dev --respawn --transpile-only src/index.ts",
    "build": "tsc -p tsconfig.build.json",
    "start": "node dist/index.js",
    "prisma:generate": "prisma generate",
    "seed": "ts-node prisma/seed.ts"
  },
  "dependencies": {
    "@prisma/client": "^5.0.0",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "helmet": "^6.0.0",
    "ws": "^8.13.0"
  },
  "devDependencies": {
    "ts-node": "^10.9.1",
    "ts-node-dev": "^2.0.0",
    "typescript": "^5.2.0",
    "prisma": "^5.0.0",
    "@types/express": "^4.17.17",
    "@types/node": "^20.0.0"
  }
}
PKG

backup_if_exists tsconfig.json
cat > tsconfig.json <<'TS'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Node",
    "outDir": "dist",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "sourceMap": true
  },
  "include": ["src", "prisma"]
}
TS

backup_if_exists tsconfig.build.json
cat > tsconfig.build.json <<'TBB'
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "declaration": true,
    "noEmitOnError": true,
    "sourceMap": false
  },
  "exclude": ["node_modules", "dist", "tests"]
}
TBB

mkdir -p src

# index.ts: health + /api/hello + users + websocket + prisma usage
backup_if_exists src/index.ts
cat > src/index.ts <<'TS'
import express from 'express';
import http from 'http';
import cors from 'cors';
import helmet from 'helmet';
import { WebSocketServer } from 'ws';
import { PrismaClient } from '@prisma/client';

const app = express();
const prisma = new PrismaClient();
const port = Number(process.env.PORT || 4000);

app.use(helmet());
app.use(cors());
app.use(express.json());

app.get('/health', (_req, res) => res.json({ status: 'ok', time: new Date().toISOString() }));

app.get('/api/hello', (_req, res) => {
  res.json({ message: 'Hello from backend!' });
});

app.get('/api/users', async (_req, res) => {
  const users = await prisma.user.findMany();
  res.json(users);
});

app.post('/api/users', async (req, res) => {
  const { email, name } = req.body;
  if (!email) return res.status(400).json({ error: 'email required' });
  try {
    const user = await prisma.user.create({ data: { email, name } });
    res.status(201).json(user);
  } catch (err) {
    res.status(500).json({ error: 'create error', detail: err });
  }
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws) => {
  ws.send(JSON.stringify({ type: 'welcome', message: 'Welcome to Awesome WS!' }));
  ws.on('message', (msg) => {
    const payload = { type: 'echo', message: String(msg), time: new Date().toISOString() };
    ws.send(JSON.stringify(payload));
  });
});

server.listen(port, () => {
  console.log(`Backend listening on http://localhost:${port}`);
});
TS

# Prisma schema inside backend (self-contained)
backup_if_exists prisma/schema.prisma
cat > prisma/schema.prisma <<'PRISMA'
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id        Int      @id @default(autoincrement())
  email     String   @unique
  name      String?
  createdAt DateTime @default(now())
}
PRISMA

# Prisma seed that lives in packages/backend/prisma
backup_if_exists prisma/seed.ts
cat > prisma/seed.ts <<'SEED'
import { PrismaClient } from '@prisma/client';
const prisma = new PrismaClient();

async function main() {
  await prisma.user.createMany({
    data: [
      { email: 'anna@example.com', name: 'Anna' },
      { email: 'luis@example.com', name: 'Luis' }
    ],
    skipDuplicates: true,
  });
  console.log('Seeded users');
}

main()
  .catch(e => { console.error(e); process.exit(1); })
  .finally(async () => { await prisma.$disconnect(); });
SEED

# Backend Dockerfile
backup_if_exists Dockerfile
cat > Dockerfile <<'DOCKER'
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --production=false
COPY . .
RUN npm run build
RUN npx prisma generate

FROM node:18-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/package*.json ./
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
CMD ["node", "dist/index.js"]
DOCKER

# return to repo root
cd ../../

# ---------- Frontend ----------
cd packages/frontend

backup_if_exists package.json
cat > package.json <<'PKG'
{
  "name": "awesome-frontend",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview --port 5173"
  },
  "dependencies": {
    "framer-motion": "^8.0.0",
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "typescript": "^5.2.0",
    "vite": "^5.0.0",
    "@vitejs/plugin-react": "^4.0.0",
    "tailwindcss": "^4.2.0",
    "postcss": "^8.5.0",
    "autoprefixer": "^10.4.0"
  }
}
PKG

backup_if_exists tsconfig.json
cat > tsconfig.json <<'TS'
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["DOM", "ES2022"],
    "jsx": "react-jsx",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true
  },
  "include": ["src"]
}
TS

# Vite config
backup_if_exists vite.config.ts
cat > vite.config.ts <<'VITE'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
});
VITE

# Tailwind config
backup_if_exists tailwind.config.cjs
cat > tailwind.config.cjs <<'TW'
module.exports = {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {},
  },
  plugins: []
}
TW

backup_if_exists index.html
cat > index.html <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>Awesome Frontend</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
HTML

mkdir -p src

backup_if_exists src/main.tsx
cat > src/main.tsx <<'TSX'
import React from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";

createRoot(document.getElementById("root")!).render(<App />);
TSX

# Fixed frontend: fetches /health instead of missing /api/hello
backup_if_exists src/App.tsx
cat > src/App.tsx <<'TSX'
import React, { useEffect, useState } from "react";
import { motion } from "framer-motion";

export default function App() {
  const [status, setStatus] = useState('loading...');
  useEffect(() => {
    fetch('/health')
      .then(r => r.json())
      .then(d => setStatus(d.status + ' @ ' + new Date(d.time).toLocaleTimeString()))
      .catch(() => setStatus('backend unreachable'));
  }, []);

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-tr from-[#0f172a] to-[#341f6f] text-slate-100 p-6">
      <motion.div initial={{opacity:0,y:20}} animate={{opacity:1,y:0}} transition={{duration:0.6}} className="max-w-3xl w-full bg-white/5 backdrop-blur rounded-2xl p-8 shadow-2xl">
        <h1 className="text-2xl font-bold">Awesome Frontend (fixed)</h1>
        <p className="mt-4">Backend health: <code className="bg-black/30 px-2 py-1 rounded">{status}</code></p>
      </motion.div>
    </div>
  );
}
TSX

backup_if_exists src/styles.css
cat > src/styles.css <<'CSS'
@tailwind base;
@tailwind components;
@tailwind utilities;
html,body,#root{height:100%}
CSS

# Frontend Dockerfile (build -> nginx)
backup_if_exists Dockerfile
cat > Dockerfile <<'DOCKER'
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:stable-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
DOCKER

# return to root
cd ../../

# ---------- Git init (optional) ----------
if command -v git >/dev/null 2>&1 && [ ! -d .git ]; then
  git init -q
  git add -A
  git commit -m "chore: scaffold fixed monorepo (no auto-install)" -q || true
  echo "Git initialized and initial commit created."
fi

# ---------- Final message ----------
echo
echo "DONE — scaffolded project WITHOUT running npm."
echo
echo "What I fixed compared to the previous version:"
echo " - No automatic npm installs or dev runs. You must run installs manually."
echo " - Prisma is now inside packages/backend/prisma (self-contained)."
echo " - Frontend fetch now calls /health (backend provides /health)."
echo " - Backend package.json seed and prisma files live in backend/prisma."
echo " - Root docker-compose.yml references ./packages/* contexts correctly."
echo
echo "Next manual steps (recommended):"
echo " 1) Backend setup:"
echo "    cd packages/backend"
echo "    npm install"
echo "    npx prisma generate"
echo "    # optional seed"
echo "    npx ts-node prisma/seed.ts"
echo "    npm run dev"
echo
echo " 2) Frontend setup:"
echo "    cd packages/frontend"
echo "    npm install"
echo "    npm run dev"
echo
echo "3) Or run entire stack with Docker (from repo root):"
echo "    docker-compose up --build"
echo
echo "If you paste any exact error messages here I will fix them fast. No auto-installs, no surprises."
