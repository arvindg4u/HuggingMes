---
title: HuggingMes
emoji: 🧠
colorFrom: purple
colorTo: blue
sdk: docker
app_port: 7860
pinned: false
license: mit
tags:
  - hermes-agent
  - opencode
  - jupyterlab
  - terminal
  - ai-agent
secrets:
  - name: LLM_API_KEY
    description: "OpenCode free tier API key (sk-...)"
  - name: LLM_MODEL
    description: "Model ID: opencode-free/deepseek-v4-flash-free"
  - name: GATEWAY_TOKEN
    description: "Strong token to secure the dashboard (openssl rand -hex 32)"
  - name: TELEGRAM_BOT_TOKEN
    description: "Telegram bot token from BotFather"
  - name: TELEGRAM_ALLOWED_USERS
    description: "Comma-separated Telegram user IDs for access"
  - name: JUPYTER_TOKEN
    description: "Optional — defaults to GATEWAY_TOKEN"
  - name: HF_TOKEN
    description: "HuggingFace token for workspace backup"
---

<!-- Badges -->
[![GitHub Stars](https://img.shields.io/github/stars/NousResearch/hermes-agent?style=flat-square)](https://github.com/NousResearch/hermes-agent)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![HF Space](https://img.shields.io/badge/🤗%20HuggingFace-Space-blue?style=flat-square)](https://huggingface.co/spaces)

**Your always-on Hermes Agent — free, no server needed.** Runs [Hermes Agent](https://hermes-agent.nousresearch.com) by Nous Research plus JupyterLab terminal on HF Spaces. Uses the **OpenCode free tier** (`opencode-free/deepseek-v4-flash-free`) — no paid API key required.

## ✨ Features

- 🔌 **OpenCode Free Tier:** Uses `opencode-free/deepseek-v4-flash-free` — zero-cost LLM access.
- 🔄 **Custom Provider System:** Maps 30+ providers (anthropic, openai, google, openrouter, groq, together, etc.) from model prefix to correct API key env var.
- ⚡ **Zero Config:** Set just 3 secrets and deploy.
- 💬 **Telegram Bot:** @Pintu_OpenClaw_bot ready to connect.
- 💻 **JupyterLab Terminal:** Web terminal at `/terminal/`.
- 🏠 **100% HF-Native:** Free tier (2 vCPU, 16GB RAM, 50GB disk).

## 🚀 Quick Start

### Step 1: Duplicate this Space

[![Duplicate this Space](https://huggingface.co/datasets/huggingface/badges/resolve/main/duplicate-this-space-xl.svg)](https://huggingface.co/spaces)

### Step 2: Add secrets in Space Settings

| Secret | Value |
|--------|-------|
| `LLM_API_KEY` | `sk-9MHgBALigYug9WbjW4U0M4Sfh7hwgzTgboYB3kF87rOJMBrHyTqoZFroXbYnLBd9` |
| `LLM_MODEL` | `opencode-free/deepseek-v4-flash-free` |
| `GATEWAY_TOKEN` | `4f2fdce07f7f2b0462acc9a36cd9027d138860ddb9d3c970763367a7d4fa1a5c` |
| `TELEGRAM_BOT_TOKEN` | `8504327676:AAG0A_7ip0t9MLukhc8jA6mSaHxVaBYHy3I` |
| `DEV_MODE` | `true` |

### Step 3: Deploy

Space builds and starts automatically. Dashboard at `https://<your-space>.hf.space/`.

## 🔄 Custom Provider System

The model prefix in `LLM_MODEL` determines which API key env var is used:

| Prefix | Env Var | Example Model |
|--------|---------|---------------|
| `opencode-free` | `CUSTOM_API_KEY` | `deepseek-v4-flash-free` |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-4-6` |
| `openai` | `OPENAI_API_KEY` | `gpt-5.4` |
| `google` | `GEMINI_API_KEY` | `gemini-2.5-flash` |
| `openrouter` | `OPENROUTER_API_KEY` | `openrouter/...` |
| `deepseek` | `DEEPSEEK_API_KEY` | `deepseek-v3.2` |
| `groq` | `GROQ_API_KEY` | `llama-4.*` |
| `together` | `TOGETHER_API_KEY` | `meta-llama/...` |
| `mistral` | `MISTRAL_API_KEY` | `mistral-large` |
| `xai` | `XAI_API_KEY` | `grok-3` |
| `nvidia` | `NVIDIA_API_KEY` | `nvidia/...` |

Also supports key pools (`ANTHROPIC_API_KEYS=key1,key2,key3` → auto-promotes first key), custom OpenAI-compatible providers via `CUSTOM_PROVIDER_NAME`/`CUSTOM_BASE_URL`/`CUSTOM_MODEL_ID`, and explicit model lists via `OPENAI_MODELS=gpt-4o,gpt-4.1`.

## 💬 Telegram Setup

The bot **@Pintu_OpenClaw_bot** is pre-configured. To authorize yourself:
1. Message the bot on Telegram
2. Check the bot logs to get your user ID
3. Add `TELEGRAM_ALLOWED_USERS=your_id` as a Space secret

## 💻 JupyterLab Terminal

Available at `/terminal/` when `DEV_MODE=true` or `GATEWAY_TOKEN` is set. Use `GATEWAY_TOKEN` to log in.

## 🏗️ Architecture

```
HF Space :7860 → Caddy reverse proxy
  ├── /             → Hermes Dashboard (:9119)
  ├── /v1/*         → OpenAI-compatible API (:8642)
  ├── /terminal/*   → JupyterLab (:8888)
  ├── /ws/*         → Hermes WebSocket (:8642)
  └── /health       → Health check (:9080)
```

## 📄 License

MIT

## 💾 HF Dataset Backup (Workspace Persistence)

HF Spaces are ephemeral — data is lost on restart. HuggingMes auto-syncs Hermes config, memory, skills, and credentials to a **private HF Dataset** so everything persists.

### Setup

1. Get a [HF access token](https://huggingface.co/settings/tokens) with `write` permission
2. Add these **Secrets** in Space Settings:
   - `HF_TOKEN` — your HF token
   - `HF_USERNAME` — your HF username (e.g. `arvindlabs`)
3. (Optional) `BACKUP_DATASET_NAME` — dataset name (default: `huggingmes-backup`)

### How it works

- **On startup:** Restores Hermes workspace from the dataset
- **Every 5 min:** Background sync loop uploads changes
- **Files synced:** `config.yaml`, `.env`, `memory/`, `skills/`, `credentials/`

Dataset is created automatically on first upload — no manual setup needed.

## 📚 Configuration Reference

| Secret | Required | Default | Description |
|--------|----------|---------|-------------|
| `LLM_API_KEY` | ✅ | — | OpenCode free tier API key |
| `LLM_MODEL` | ✅ | — | `opencode-free/deepseek-v4-flash-free` |
| `GATEWAY_TOKEN` | ✅ | — | Dashboard auth token |
| `TELEGRAM_BOT_TOKEN` | ❌ | — | Telegram bot token |
| `TELEGRAM_ALLOWED_USERS` | ❌ | — | Comma-separated Telegram user IDs |
| `HF_TOKEN` | ❌ | — | HF token for dataset backup |
| `HF_USERNAME` | ❌ | — | HF username for dataset backup |
| `BACKUP_DATASET_NAME` | ❌ | `huggingmes-backup` | Dataset name for backup |
| `SYNC_INTERVAL` | ❌ | `300` | Backup sync interval (seconds) |
| `DEV_MODE` | ❌ | — | Enable JupyterLab terminal |
