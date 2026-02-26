# callsheet-deploy

Deployment configuration for the Callsheet application.

This repo contains no application code — it orchestrates the UI and API services and owns all deployment config. Both app repos must be cloned as siblings of this directory:

```
projects/
  callsheet-deploy/   ← this repo
  callsheet-ui/
  callsheet-api/
```

## How it works

```
Internet
  │
  ▼ :80 (redirect) / :443 (HTTPS)
Caddy  ──── automatic TLS via Let's Encrypt (sslip.io domain)
  │
  ▼ :80 (internal)
Nginx (inside the UI container)
  ├── /          → React static files
  └── /api/*     → api:8080 (internal)
                       │
                       ▼
                    Go API
```

Caddy handles TLS termination. The UI and API containers are not exposed to the host — all traffic enters through Caddy.

---

## Running locally

```bash
docker compose up --build
```

Locally, Caddy will attempt to obtain a TLS cert. If you just want plain HTTP for local dev, comment out the Caddyfile and map port 80 on the `ui` service instead.

---

## Production setup (Oracle Cloud Always Free)

### 1. Create a free Oracle Cloud account

Sign up at https://www.oracle.com/cloud/free/. The Always Free tier includes a VM that is genuinely free forever — no credit card charges after the trial ends.

### 2. Provision a VM

In the Oracle Cloud Console:

1. **Compute → Instances → Create Instance**
2. Image: **Ubuntu 24.04**
3. Shape: `VM.Standard.E2.1.Micro` (Always Free) — 1 OCPU, 1 GB RAM is enough
4. Add your SSH public key so you can log in
5. Note the **Public IP address** of the instance once it's running

**Open ports 80 and 443** — this is easy to miss:

- Go to the instance's **Subnet → Security List**
- Add two ingress rules: TCP port 80 and TCP port 443, source `0.0.0.0/0`

Also open the ports in the VM's own firewall:

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80  -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

### 3. Install Docker on the VM

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # lets you run docker without sudo
# Log out and back in for the group change to take effect
```

### 4. Clone all three repos

```bash
mkdir ~/projects && cd ~/projects
git clone https://github.com/<you>/callsheet-api.git
git clone https://github.com/<you>/callsheet-ui.git
git clone https://github.com/<you>/callsheet-deploy.git
```

### 5. Create the `.env` file

```bash
cd ~/projects/callsheet-deploy
cat > .env <<'EOF'
TMDB_API_KEY=your_tmdb_api_key_here
CALLSHEET_HOST=<server-public-ip>.sslip.io
EOF
```

Replace `<server-public-ip>` with the actual IP (e.g. `1.2.3.4.sslip.io`).
[sslip.io](https://sslip.io) resolves `<ip>.sslip.io` to `<ip>` — no DNS setup needed, and Caddy can obtain a real Let's Encrypt cert for it.

### 6. First deploy

```bash
chmod +x ~/projects/callsheet-deploy/scripts/deploy.sh
~/projects/callsheet-deploy/scripts/deploy.sh
```

The app will be live at `https://<server-public-ip>.sslip.io` once Caddy obtains its certificate (usually a few seconds).

---

## Continuous deployment via GitHub Actions

Every repo has a `.github/workflows/deploy.yml` that SSHes into the server and runs `deploy.sh` whenever `main` is pushed. The same three secrets must be added to **each** of the three repos.

### Generate a deploy SSH key (on your local machine)

```bash
ssh-keygen -t ed25519 -C "callsheet-deploy" -f ~/.ssh/callsheet_deploy -N ""
```

Add the **public key** to the server's authorized keys:

```bash
cat ~/.ssh/callsheet_deploy.pub | ssh ubuntu@<server-ip> "cat >> ~/.ssh/authorized_keys"
```

### Add secrets to GitHub

For each of the three repos, go to **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | The server's public IP address |
| `DEPLOY_USER` | `ubuntu` (or whatever your VM username is) |
| `DEPLOY_SSH_KEY` | The contents of `~/.ssh/callsheet_deploy` (the **private** key) |

### How deploys work

```
Push to main (any repo)
  → GitHub Actions
    → SSH into server
      → scripts/deploy.sh
        → git pull (all three repos)
        → docker compose up --build -d --remove-orphans
```

---

## Useful commands

```bash
# Follow logs from all containers
docker compose logs -f

# Follow logs from one container
docker compose logs -f api

# Rebuild and restart without pulling new code
cd ~/projects/callsheet-deploy && docker compose up --build -d

# Stop everything
docker compose down

# Stop and remove volumes (resets Caddy's cert cache)
docker compose down -v
```
