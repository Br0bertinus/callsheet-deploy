# callsheet-deploy

Deployment configuration for the Callsheet application.

This repo contains no application code — it owns the Docker Compose stack, Caddy config, and all deployment secrets. Only this repo needs to be cloned on the server; Docker images are built in CI and pulled from GHCR.

## How it works

```
Internet
  │
  ▼ :80 (redirect) / :443 (HTTPS)
Caddy  ──── automatic TLS via Let's Encrypt
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

### 2. Generate an SSH key pair (on your local machine)

You'll need this to log into the VM. Check if you already have one:

```bash
ls ~/.ssh/*.pub
```

If nothing is listed, generate one:

```bash
ssh-keygen -t ed25519 -C "my-key"
```

Accept all defaults. This creates `~/.ssh/id_ed25519` (private) and `~/.ssh/id_ed25519.pub` (public). Never share the private key.

### 3. Provision a VM

In the Oracle Cloud Console, go to **Compute → Instances → Create Instance**:

- **Image**: Ubuntu 24.04
- **Shape**: `VM.Standard.E2.1.Micro` (Always Free) — 1 OCPU, 1 GB RAM
- **Networking**: Under the Primary VNIC section, select **"Create new virtual cloud network"** and **"Create new public subnet"** — leave all auto-populated values as-is. Ignore the warning about additional options.
- **Public IP**: With a public subnet selected, Oracle automatically assigns a public IP and the toggle is locked to enabled.
- **SSH keys**: Choose **"Paste public key"** and paste the contents of `~/.ssh/id_ed25519.pub`:
  ```bash
  cat ~/.ssh/id_ed25519.pub
  ```
- **Storage**: Leave defaults (47 GB is plenty).

Click **Create**. Once the instance reaches the Running state, note the **Public IP address**.

**If the instance shows no public IP after creation**, assign one manually:
- Click the instance → scroll to **Primary VNIC** → click the VNIC link → **IPv4 Addresses** → three-dot menu next to the private IP → **Edit** → select **Ephemeral public IP** → Save.

### 4. Open ports 80 and 443

Oracle has two independent firewalls — both must be configured.

**Cloud Security List** (in the Oracle console):

1. From the instance details page, scroll to **Primary VNIC** → click the **subnet** link
2. Click **Security Lists** → click the default security list
3. Click **Add Ingress Rules** and add two rules (one at a time):

| Field | Value |
|---|---|
| Stateless | Off (leave unchecked) |
| Source CIDR | `0.0.0.0/0` |
| IP Protocol | TCP |
| Destination Port Range | `80` |

Repeat for port `443`.

**VM iptables** (over SSH — do this after step 5):

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80  -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

`netfilter-persistent save` makes the rules persist across reboots.

### 5. SSH into the VM

```bash
ssh ubuntu@<your-public-ip>
```

Run the iptables commands from step 4 now that you're in.

### 6. Install Docker on the VM

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu
```

**Log out and back in** — the group change requires a new session to take effect:

```bash
exit
```
```bash
ssh ubuntu@<your-public-ip>
```

Verify it works:

```bash
docker run hello-world
```

### 7. Clone this repo on the VM

Only `callsheet-deploy` needs to be on the server. Docker images for the UI and API are built in GitHub Actions and pulled from GHCR.

```bash
mkdir ~/projects && cd ~/projects
git clone https://github.com/<you>/callsheet-deploy.git
```

If the repo is private, use a Personal Access Token (GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic)**) as the password when prompted.

### 8. Log into GHCR on the VM

The server needs to pull private images from GitHub Container Registry. Use your Personal Access Token (needs `read:packages` scope):

```bash
echo "<your-token>" | docker login ghcr.io -u <your-github-username> --password-stdin
```

### 9. Create the `.env` file

```bash
cd ~/projects/callsheet-deploy
cat > .env <<'EOF'
TMDB_API_KEY=your_tmdb_v4_read_access_token_here
CALLSHEET_HOST=callsheet.your-domain.com
EOF
echo "IMAGE_OWNER=your-github-username-lowercase" >> .env
```

**Important:** `TMDB_API_KEY` must be the **v4 Read Access Token** (a long JWT), not the short v3 API key. Find it at themoviedb.org → Settings → API → **API Read Access Token**.

Replace `callsheet.your-domain.com` with your actual hostname (see [Custom domain setup](#custom-domain-setup) below). If you don't have a domain yet, you can use `<server-public-ip>.sslip.io` as a temporary hostname — [sslip.io](https://sslip.io) resolves `<ip>.sslip.io` to `<ip>` with no DNS registration needed.

The `.env` is gitignored and will be overwritten on every automated deploy with values from GitHub secrets.

### 10. First deploy

```bash
cd ~/projects/callsheet-deploy
bash scripts/deploy.sh
```

The script pulls the latest images from GHCR and starts all three containers. Make sure CI has already run at least once in `callsheet-ui` and `callsheet-api` to push images before running this — otherwise there's nothing to pull.

When it completes, all three containers should show `Up` in the status table. The app will be live at your configured hostname once Caddy obtains its TLS certificate (usually a few seconds after the first request).

---

## Custom domain setup

For a proper domain, [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/) sells domains at cost with no markup and provides excellent DNS management.

The recommended structure for hosting multiple games under one domain:

```
your-domain.com                 → landing page (future)
callsheet.your-domain.com       → Callsheet
othergame.your-domain.com       → future games
```

### 1. Add DNS records in Cloudflare

Go to your domain → **DNS → Records** and add:

| Type | Name | IPv4 address | Proxy status |
|---|---|---|---|
| A | `*` | `<your-server-ip>` | DNS only (grey cloud) |
| A | `@` | `<your-server-ip>` | DNS only (grey cloud) |

The wildcard `*` record covers all subdomains automatically — you never need to touch DNS again when adding new games.

**Important:** Keep proxy status as **DNS only** (grey cloud). Cloudflare's orange-cloud proxy intercepts HTTPS and conflicts with Caddy's Let's Encrypt cert process.

### 2. Update the server's `.env`

SSH into the server and update `CALLSHEET_HOST`:

```bash
cd ~/projects/callsheet-deploy
nano .env
# set CALLSHEET_HOST=callsheet.your-domain.com
```

### 3. Recreate the Caddy container

`docker compose restart` keeps the old environment. Use `up -d` to recreate with the new env vars:

```bash
docker compose up -d caddy
```

Caddy will automatically obtain a new Let's Encrypt cert for the new hostname within seconds of the first request.

---

## Continuous deployment via GitHub Actions

CI and CD are intentionally separated across repos:

- **`callsheet-ui` and `callsheet-api`** own CI — they build Docker images and push them to GHCR, then fire a deploy trigger.
- **`callsheet-deploy`** owns CD — it receives the trigger, SSHes into the server, and runs `scripts/deploy.sh`, which only pulls the pre-built images and restarts the stack.

### How deploys work

```
Push to main in callsheet-ui or callsheet-api
  → GitHub Actions (CI):
      → build Docker image
      → push to GHCR (ghcr.io/<owner>/<repo>:latest and :<git-sha>)
      → fire repository_dispatch → callsheet-deploy

callsheet-deploy receives dispatch (or is pushed/triggered directly)
  → GitHub Actions (CD):
      → SSH into server
        → write .env from GitHub secrets
        → scripts/deploy.sh
            → git pull (callsheet-deploy only)
            → docker compose pull
            → docker compose up -d --remove-orphans
            → health check (verify all containers are running)
```

The SHA tag on each image provides a rollback path if needed.

### Generate a deploy SSH key (on your local machine)

This is a separate key from your personal login key — it's used only by GitHub Actions.

```bash
ssh-keygen -t ed25519 -C "callsheet-deploy" -f ~/.ssh/callsheet_deploy -N ""
```

Add the **public key** to the server's authorized keys:

```bash
cat ~/.ssh/callsheet_deploy.pub | ssh ubuntu@<server-ip> "cat >> ~/.ssh/authorized_keys"
```

### Add secrets to GitHub

**`callsheet-deploy` — all deploy secrets live here:**

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | The server's public IP address |
| `DEPLOY_USER` | `ubuntu` |
| `DEPLOY_SSH_KEY` | Contents of `~/.ssh/callsheet_deploy` (private key, no `.pub`) |
| `TMDB_API_KEY` | Your TMDB **v4 Read Access Token** (long JWT — not the short v3 API key) |
| `CALLSHEET_HOST` | Your hostname (e.g. `callsheet.your-domain.com`) |

To get the private key contents:
```bash
cat ~/.ssh/callsheet_deploy
```
Copy everything including the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----` lines.

**`callsheet-api` and `callsheet-ui` — one secret each:**

| Secret | Value |
|---|---|
| `GH_PAT` | A GitHub Personal Access Token (classic) with `repo` and `write:packages` scope |

This token is used to push images to GHCR and to trigger the deploy dispatch. Create one at: GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic)**.

### Test the pipeline

```bash
cd path/to/callsheet-ui  # or callsheet-api
git commit --allow-empty -m "test: trigger CD pipeline"
git push
```

Go to the repo on GitHub → **Actions** and watch the CI workflow run. When it completes, the deploy will appear in `callsheet-deploy`'s Actions tab. You can also trigger a deploy directly from `callsheet-deploy` → Actions → Deploy → **Run workflow**.

---

## Useful commands

```bash
# Follow logs from all containers
docker compose logs -f

# Follow logs from one container
docker compose logs -f api

# Pull latest images and restart (same as what deploy.sh does)
cd ~/projects/callsheet-deploy && docker compose pull && docker compose up -d

# Restart with the current images (no pull)
docker compose up -d

# Stop everything
docker compose down

# Stop and remove volumes (resets Caddy's cert cache)
docker compose down -v
```
