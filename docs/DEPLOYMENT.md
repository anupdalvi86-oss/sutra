# Sutra deployment

Sutra runs Hermes Agent in gateway mode using the official `nousresearch/hermes-agent:latest` Docker image.

## Railway service

Deploy this repository with the included Dockerfile and `railway.json`.

Attach a persistent Railway volume mounted at `/opt/data`. Hermes stores configuration, sessions, memories, skills, cron definitions and logs there.

## Required secrets

Configure these in Railway, never in Git:

- `OPENAI_API_KEY` or another supported Hermes model-provider credential
- `TELEGRAM_BOT_TOKEN` when Telegram is enabled
- `SUPABASE_URL`
- server-side Supabase credential used by the Sutra integration layer
- GitHub credential only when an engineering worker requires it

## Runtime

The container seeds `hermes/SOUL.md` into a fresh Hermes volume and starts `hermes gateway run`.

## Security

Do not expose model-provider, Supabase service, Telegram or GitHub secrets to agent prompts. Use least-privilege credentials and tool-level authorization. Financial/governance policy is authoritative in Supabase and cannot be raised by the governed agent itself.

## Resource guidance

Hermes documents 1 GB RAM as a minimum and 2–4 GB as recommended, especially when browser tooling is used. Persistent state is stored under `/opt/data`.
