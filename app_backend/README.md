# WayFindCL Backend

Fiber-based REST API skeleton ready for MariaDB.

## Endpoints
- `GET /api/health` → `{ status: "ok" }`
- `POST /api/login` → `{ token, user }` (placeholder for now)

## Run
```pwsh
cd app_backend
Copy-Item .env.example .env
# edit .env values for MariaDB
 go build ./cmd/server
 .\server.exe
```

## Env vars
- `PORT` (default `8080`)
- `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME`
