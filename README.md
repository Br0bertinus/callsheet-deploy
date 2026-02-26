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
CALLSHEET_HOST=<server-public-ip>.sslip.io
EOF
```

Replace `<server-public-ip>` with the actual IP (e.g. `163.192.44.127.sslip.io`).
[sslip.io](https://sslip.io) resolves `<ip>.sslip.io` to `<ip>` — no DNS registration needed, and Caddy can obtain a real Let's Encrypt cert for it automatically.

### 9. First deploy

```bash
chmod +x ~/projects/callsheet-deploy/scripts/deploy.sh
~/projects/callsheet-deploy/scripts/deploy.sh
```

The first build takes a few minutes. When it completes, all three containers should show `Up` in the status table.

The app will be live at `https://<server-public-ip>.sslip.io` once Caddy obtains its TLS certificate (usually a few seconds after first request).

---

## Continuous deployment via GitHub Actions

Every repo has a `.github/workflows/deploy.yml` that SSHes into the server and runs `deploy.sh` whenever `main` is pushed. The same three secrets must be added to **each** of the three repos.

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

For each of the three repos, go to **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | The server's public IP address |
| `DEPLOY_USER` | `ubuntu` |
| `DEPLOY_SSH_KEY` | The contents of `~/.ssh/callsheet_deploy` (the **private** key — no `.pub`) |

To get the private key contents:
```bash
cat ~/.ssh/callsheet_deploy
```
Copy everything including the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----` lines.

### Test the pipeline

```bash
cd path/to/any-of-the-three-repos
git commit --allow-empty -m "test: trigger CD pipeline"
git push
```

Go to the repo on GitHub → **Actions** and watch the workflow run.

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
