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

### 7. Clone all three repos

```bash
mkdir ~/projects && cd ~/projects
git clone https://github.com/<you>/callsheet-api.git
git clone https://github.com/<you>/callsheet-ui.git
git clone https://github.com/<you>/callsheet-deploy.git
```

Note: GitHub no longer accepts passwords for HTTPS clones. If your repos are private, use a Personal Access Token (GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic)**) as the password when prompted.

### 8. Create the `.env` file

```bash
cd ~/projects/callsheet-deploy
cat > .env <<'EOF'
TMDB_API_KEY=your_tmdb_api_key_here
CALLSHEET_HOST=callsheet.your-domain.com
EOF
```

Replace `callsheet.your-domain.com` with your actual hostname (see [Custom domain setup](#custom-domain-setup) below).

If you don't have a domain yet, you can use `<server-public-ip>.sslip.io` as a temporary hostname — [sslip.io](https://sslip.io) resolves `<ip>.sslip.io` to `<ip>` with no DNS registration needed.

### 9. First deploy

```bash
chmod +x ~/projects/callsheet-deploy/scripts/deploy.sh
~/projects/callsheet-deploy/scripts/deploy.sh
```

The first build takes a few minutes. When it completes, all three containers should show `Up` in the status table.

The app will be live at your configured hostname once Caddy obtains its TLS certificate (usually a few seconds after first request).

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

`callsheet-deploy` is the single source of truth for all deployment logic and secrets. App repos (`callsheet-api`, `callsheet-ui`) know nothing about the server — they only fire a trigger event when pushed.

### How deploys work

```
Push to main (any repo)
  → GitHub Actions fires repository_dispatch → callsheet-deploy

callsheet-deploy receives dispatch (or is pushed directly)
  → GitHub Actions
    → SSH into server
      → write .env from GitHub secrets
      → scripts/deploy.sh
        → git pull (all three repos)
        → docker compose up --build -d --remove-orphans
```

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
| `TMDB_API_KEY` | Your TMDB API key |
| `CALLSHEET_HOST` | Your hostname (e.g. `callsheet.black-inc.dev`) |

To get the private key contents:
```bash
cat ~/.ssh/callsheet_deploy
```
Copy everything including the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----` lines.

**`callsheet-api` and `callsheet-ui` — one secret each:**

| Secret | Value |
|---|---|
| `GH_PAT` | A GitHub Personal Access Token with `repo` scope |

To create a PAT: GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic)** → New token → check `repo` scope.

### Test the pipeline

```bash
cd path/to/any-of-the-three-repos
git commit --allow-empty -m "test: trigger CD pipeline"
git push
```

Go to the repo on GitHub → **Actions** and watch the workflow run. For app repos, the workflow fires a dispatch event and the actual deploy will appear in `callsheet-deploy`'s Actions tab.

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
