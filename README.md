# n8n Installation Script

Automated Docker Compose deployment for an existing Traefik server.

## Included

- n8n
- PostgreSQL 18
- n8n self-hosted AI Assistant module (`instance-ai`)
- n8n bundled AI sandbox service
- SearXNG private web search with JSON API enabled
- Persistent Docker volumes
- Traefik HTTPS routing
- Automatically generated secrets
- OpenAI API key intentionally left blank

## Requirements

- Ubuntu server
- Docker Engine
- Docker Compose v2
- Existing Traefik installation
- External Docker network named `proxy`
- DNS record for `n8n.cqdxbrasil.com` pointing to the server
- Recommended minimum for the AI sandbox: 4 GB RAM and 2 vCPUs

## Install

```bash
git clone https://github.com/dev-jmatias/n8n-instalation-script.git
cd n8n-instalation-script
chmod +x install-n8n.sh
sudo ./install-n8n.sh
```

Default URL:

```text
https://n8n.cqdxbrasil.com
```

To use another domain:

```bash
sudo N8N_DOMAIN=n8n.example.com ./install-n8n.sh
```

## Add the OpenAI API key

The installer deliberately does not put an OpenAI key in GitHub or generate one.

After installation:

```bash
sudo nano /opt/apps/n8n/.env
```

Set:

```dotenv
N8N_INSTANCE_AI_MODEL_API_KEY=YOUR_OPENAI_API_KEY
```

Then restart n8n:

```bash
cd /opt/apps/n8n
sudo docker compose up -d n8n
```

The default model is configured as:

```dotenv
N8N_INSTANCE_AI_MODEL=openai/gpt-4.1
```

It can be changed in `/opt/apps/n8n/.env`.

## Useful commands

```bash
cd /opt/apps/n8n
sudo docker compose ps
sudo docker compose logs -f n8n
sudo docker compose logs -f sandbox-api
sudo docker compose logs -f sandbox-runner-1
sudo docker compose logs -f searxng
```

## Architecture

Only n8n joins the existing public `proxy` Docker network. PostgreSQL, SearXNG, sandbox API and sandbox runner remain on the stack's private `internal` network and publish no host ports.

SearXNG enables both HTML and JSON result formats because the n8n AI Assistant uses its HTTP search API.

## Security warning

The bundled n8n sandbox runner uses a privileged Docker-in-Docker container. Do not expose its ports publicly. n8n currently describes the bundled sandbox as suitable for development/testing and recommends a dedicated production sandbox provider such as Daytona for production deployments.

Secrets are generated locally in `/opt/apps/n8n/.env`. The `.env` file should never be committed to Git.
