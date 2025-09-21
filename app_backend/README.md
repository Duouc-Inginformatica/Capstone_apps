# WayFindCL Backend

Fiber-based REST API with MariaDB. Provides registration and login with bcrypt and a minimal HS256 token.

## Endpoints
- `GET /api/health` → `{ "status": "ok" }`
- `POST /api/register` → `{ token, user }` (creates a new user)
	- Body JSON: `{ "username": "john", "email": "john@doe.com", "password": "secret", "name": "John" }`
	- 409 if username/email already exists
- `POST /api/login` → `{ token, user }` (authenticates by username/password)
	- Body JSON: `{ "username": "john", "password": "secret" }`
	- 401 on invalid credentials

## Run
```powershell
cd app_backend
Copy-Item .env.example .env
# Edit .env with your DB and JWT_SECRET
# (Optional) Initialize DB schema/content directly in MySQL/MariaDB
# mysql -u root -p < default.sql
go mod tidy
go build ./cmd/server
./server.exe
```

Server logs: `server listening on :8080`

## Env vars
- `PORT` (default `8080`)
- `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME`
- `JWT_SECRET` (HS256 secret for token signing)
  
### MariaDB/MySQL auth plugin note
If you see errors like `unknown auth plugin: auth_gssapi_client`, it's because the user is configured with an unsupported plugin. The Go MySQL driver can't override this via DSN.

Fix by creating or altering the DB user to a supported plugin:

MariaDB 10.4+ (use mysql_native_password):
```sql
CREATE USER IF NOT EXISTS 'wayfind_app'@'%' IDENTIFIED BY 'Strong#Pass2025';
ALTER USER 'wayfind_app'@'%' IDENTIFIED VIA mysql_native_password;
ALTER USER 'wayfind_app'@'%' IDENTIFIED BY 'Strong#Pass2025';
GRANT ALL PRIVILEGES ON `wayfindcl`.* TO 'wayfind_app'@'%';
FLUSH PRIVILEGES;
```

MySQL 8 (use caching_sha2_password or mysql_native_password):
```sql
CREATE USER IF NOT EXISTS 'wayfind_app'@'%' IDENTIFIED WITH caching_sha2_password BY 'Strong#Pass2025';
-- or: IDENTIFIED WITH mysql_native_password BY 'Strong#Pass2025';
GRANT ALL PRIVILEGES ON `wayfindcl`.* TO 'wayfind_app'@'%';
FLUSH PRIVILEGES;
```

## SQL bootstrap
- A provided `default.sql` contains:
	- `CREATE DATABASE wayfindcl` and `users` table
	- Optional creation of an app user (commented; choose the plugin for your server)
	- Optional demo user `demo/demo1234`
  
To apply it:
```powershell
mysql -u root -p < default.sql
```

## Notes
- The token is a minimal JWT-like HS256 token (base64url header/payload + signature). For production, switch to a mature JWT library to support exp/nbf/aud, key rotation, etc.
- Schema is ensured on boot via `EnsureSchema()` and creates a `users` table if it does not exist.
