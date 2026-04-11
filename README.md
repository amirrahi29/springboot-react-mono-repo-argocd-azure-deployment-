# rahi-chat monorepo

Layout: **`backend/`** (Spring Boot) + **`frontend/`** (React + Vite), one **container** / **JAR** for production.

```
.
├── backend/                 # Spring Boot 4, Java 17, Gradle; REST at /api/**
│   └── Dockerfile           # build context = repo root
├── frontend/                # React 19 + Vite 6 + ESLint + TypeScript
├── docker-compose.yml       # docker compose up — full stack image
├── Makefile                 # make dev-backend | dev-frontend | docker-build
└── gitops/                  # Helm + Argo CD
```

| Concern | Where |
|--------|--------|
| HTTP API | `GET /api/*` (e.g. `/api/data`, `/api/healthz`) |
| Browser UI | `GET /` → static files from `classpath:/static/` (Vite `dist`); deep client routes need extra config if you use React Router |
| Gradle → npm | `backend/build.gradle` uses **node-gradle** on `../frontend` |
| Fast Java tests | `./gradlew test -PskipWeb` (no npm) |
| Frontend CI | `npm ci` in **`frontend/`** (lint + typecheck) |

### Branches → AKS / Argo

| Git branch | Argo app name | Kubernetes namespace | Helm overlay |
|------------|---------------|----------------------|--------------|
| `main` | `rahi-chat-app-main` | `main` | `values-main.yaml` |
| `dev` | `rahi-chat-app-dev` | `dev` | `values-dev.yaml` |
| `staging` | `rahi-chat-app-staging` | `staging` | `values-staging.yaml` |
| `uat` | `rahi-chat-app-uat` | `uat` | `values-uat.yaml` |

Push on a branch updates that branch’s image tag file and (on app/gitops changes) runs the matching deploy verify. Work on **`dev`** locally: `git checkout dev` — CI builds tag `dev-<sha>` and bumps **`values-dev.yaml`** on the **`dev`** branch; Argo syncs branch **`dev`** into namespace **`dev`**.

## Prerequisites

- Java **17**, **Docker** (optional)
- **Node 22** + npm (for `frontend/`)

## Local development

### Ek command: sirf backend chalao → React bhi same server par

```bash
cd backend && ./gradlew bootRun
```

Gradle pehle **`frontend/`** par `npm` + `vite build` chalata hai, phir UI files **`build/resources/main/static/`** mein aa kar Spring Boot ke classpath se **`http://localhost:8081/`** par serve hoti hain. **`/api/*`** bhi isi port par hai.

- **`-PskipWeb` mat lagao** — warna sirf API milega, UI nahi.
- **IDE se seedha `main()` Run** karne par yeh frontend build kabhi‑kabhi skip ho sakta hai. Behtar: terminal se `./gradlew bootRun`, ya IDE mein **Gradle → bootRun** / “Delegate build/run to Gradle”.

### Do terminals (Vite hot reload ke liye)

```bash
make dev-backend    # :8081 — API + embedded UI (Gradle build)
make dev-frontend   # :5173 — Vite, /api → :8081
```

Open **http://localhost:5173**. API direct: **http://localhost:8081/api/data**.

## Quality checks

```bash
make test-backend
make verify-frontend
```

Or: `cd frontend && npm ci && npm run lint && npm run typecheck`.

## Docker

```bash
make docker-build
# or
docker compose up --build
```

Image listens on **8081** (override with `SERVER_PORT` / Helm `service.port`).

## GitOps

`gitops/project.yaml` drives repo URL, ACR, AKS, Helm chart. After edits:

```bash
python3 gitops/apply-project-config.py --sync-files
python3 gitops/apply-project-config.py --helm-all
```

## CI

`.github/workflows/ci.yml`: runs on **`main`**, **`dev`**, **`staging`**, **`uat`**. Backend/frontend checks, image build + `values-<branch>.yaml` bump on app changes, Helm validate, Argo manifest apply on gitops changes (any of those branches), post-deploy verify using the **current branch name** as the target namespace / Argo app.

## Cursor / VS Code: `SpringApplication cannot be resolved` / `jdt.ls-java-project/bin`

Agar terminal mein aisa dikhe:

`java ... -cp .../redhat.java/jdt_ws/jdt.ls-java-project/bin com.chat.app.ChatAppApplication`

matlab **Run** button **Gradle classpath use nahi kar raha** — sirf language server ka khokhla project, isliye `SpringApplication` runtime par missing.

**Sab se safe:** terminal se `cd backend && ./gradlew bootRun`.

**Theek se IDE chalane ke liye:**

1. Is repo folder ko Cursor/VS Code mein **Open Folder** se khol kar **Gradle for Java** se `backend/` import karo.
2. **Extension Pack for Java** + **Gradle for Java** install karo.
3. Status bar par Gradle import complete hone do; phir **Run and Debug** → **Spring Boot (Gradle — backend)**.
4. Ya **Terminal → Run Task** se `bootRun` (agar tasks define hon).
5. Kabhi kabhi **Java: Clean Java Language Server Workspace** se reload karna padta hai.

Agar **Run | Debug code lens** galat classpath use kare, `.vscode/settings.json` mein `java.debug.settings.enableRunDebugCodeLens` band rakho ya `false` set karo jab tak Gradle project theek attach na ho.
