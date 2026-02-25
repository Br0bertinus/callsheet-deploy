# callsheet-deploy

Deployment configuration for the Callsheet application.

This repo contains no application code — it only orchestrates the UI and API services. Both repos must be cloned as siblings of this directory:

```
Projects/
  callsheet-deploy/   ← this repo
  callsheet-ui/
  callsheet-api/
```

## Running locally

```bash
docker compose up --build
```

App will be at http://localhost.

## Running on a server

1. Clone all three repos as siblings on the server
2. `cd callsheet-deploy`
3. `docker compose up --build -d`

The `-d` flag runs the containers in the background. To follow logs:

```bash
docker compose logs -f
```

To stop:

```bash
docker compose down
```

## How it works

Nginx (inside the UI container) serves the React app and proxies all `/api/*` requests to the API container. The API container is not exposed to the host — all traffic reaches it through Nginx.

```
Browser → :80 (Nginx) → /          → React static files
                      → /api/*     → api:8080
```
