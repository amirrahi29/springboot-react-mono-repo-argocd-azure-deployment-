# Security

## Reporting

Report suspected vulnerabilities via [GitHub Security Advisories](https://github.com/amirrahi29/springboot-react-mono-repo-argocd-azure-deployment-/security/advisories/new) instead of a public issue. Include reproduction steps, affected versions or branches, and impact if known.

## Practices in this repo

- Container runs as non-root (`USER spring`), read-only root filesystem with `/tmp` emptyDir, dropped capabilities, `seccompProfile: RuntimeDefault`.
- CI runs `./gradlew test -PskipWeb` in `backend/` when app paths change or on pull requests; frontend runs ESLint and TypeScript in `frontend/`.

Rotate **`AZURE_CLIENT_SECRET`** or **`AZURE_CREDENTIALS`** and Argo admin access regularly; prefer GitHub→Azure OIDC in production (no SP password in GitHub).
