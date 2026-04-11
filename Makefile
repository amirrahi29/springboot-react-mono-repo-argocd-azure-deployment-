# Spring Boot backend + Vite frontend
.PHONY: help dev-backend dev-frontend test-backend verify-frontend docker-build

help:
	@echo "make dev-backend    — Spring Boot on :8081 (embeds frontend via Gradle)"
	@echo "make dev-frontend   — Vite on :5173, proxies /api → :8081"
	@echo "make test-backend   — Gradle tests (-PskipWeb)"
	@echo "make verify-frontend — npm ci + lint + typecheck in frontend/"
	@echo "make docker-build   — docker build -f backend/Dockerfile ."

dev-backend:
	cd backend && ./gradlew bootRun

dev-frontend:
	cd frontend && npm install && npm run dev

test-backend:
	cd backend && ./gradlew test --no-daemon -PskipWeb

verify-frontend:
	cd frontend && npm ci && npm run lint && npm run typecheck

docker-build:
	docker build -f backend/Dockerfile -t rahi-chat-app:local .
