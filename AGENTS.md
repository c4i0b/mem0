# AGENTS.md

This file provides context for AI coding assistants (Claude Code, Cursor, GitHub Copilot, Codex, etc.) working with the Mem0 repository.

---

## Fork Overlay — Self-Managed Update Layer

This is a **fork of [mem0ai/mem0](https://github.com/mem0ai/mem0)** with a thin overlay of customizations for self-hosted deployment. The overlay must be preserved when syncing from upstream.

### Remotes

```
origin   = git@github.com:c4i0b/mem0    (our fork)
upstream = https://github.com/mem0ai/mem0 (vanilla upstream — ADD if missing)
```

If `upstream` remote is missing, create it:
```bash
git remote add upstream https://github.com/mem0ai/mem0.git
git fetch upstream
```

### Overlay Manifest

Every file below carries custom changes. When upstream modifies these files, conflicts must be resolved by merging upstream changes INTO our custom versions (not the other way around).

| File | Purpose | Key Customizations |
|------|---------|-------------------|
| `openmemory/api/Dockerfile.standalone` | Standalone container image (Ollama + mem0) | Embeds Ollama binary, installs faiss-cpu, copies entrypoint |
| `openmemory/api/entrypoint.sh` | Container startup | Starts Ollama → pulls embedder model → runs uvicorn |
| `openmemory/api/app/routers/config.py` | Config API endpoints | `openai_base_url` field on `LLMConfig` and `EmbedderConfig` (upstream bugfix) |
| `openmemory/api/app/routers/memories.py` | Memory CRUD endpoints | Flexible `data` field typing (`Union[str, List[Dict]]`) |
| `openmemory/api/app/routers/platform.py` | Platform API router (NEW FILE) | Full custom route for Platform API compatibility |
| `openmemory/api/app/routers/__init__.py` | Router registration | Registers `platform` router |
| `openmemory/api/app/utils/memory.py` | Memory client factory | `get_memory_client()` with env-based config |
| `openmemory/api/app/utils/categorization.py` | Memory categorization | Custom categorization logic |
| `openmemory/api/main.py` | FastAPI app entry | Custom startup/lifespan |
| `openmemory/api/requirements.prod.txt` | Python dependencies | Adds faiss-cpu, minimal deps |
| `openmemory/api/.dockerignore` | Docker build context | Custom exclusions + `.env` security block |
| `openmemory/api/.env.template` | Config template (tracked in git) | Documents all env vars — copy to `~/.local/share/mem0/.env` |
| `openmemory/api/.env` | Runtime config (NOT in git) | Lives at `~/.local/share/mem0/.env`, mounted read-only into container |
| `start.sh` / `stop.sh` | Host-side container lifecycle | Podman run/rm wrappers |
| `.devcontainer/` | Dev environment for offline development | Mock Ollama + OpenAI, compose with API + UI + mock services |
| `.devcontainer/mock_services.py` | Mock server for LLM/embedder | Hash-based 768-dim embeddings, canned OpenAI chat responses |
| `openmemory/api/tests/unit/test_overlay.py` | Fork overlay regression tests | Pydantic fields, config factory, categorization lazy init, data typing |
| `openmemory/api/tests/conftest.py` | Test fixtures for integration tests | Mocked LLM + embedder, httpx AsyncClient |
| `openmemory/api/tests/test_api.py` | API REST integration tests | Ping, config, memories CRUD, stats |

### Runtime Configuration (not in git, persistent in container)

- `.env` is now mounted at runtime (not baked into image). Lives at `~/.local/share/mem0/.env`. Template at `openmemory/api/.env.template`.
- Persistent data lives at `~/.local/share/mem0/` (mounted into container):
  - `.env` — runtime config (mounted read-only into container)
  - `ollama/` — Ollama model storage
  - `data/` — FAISS index + metadata
- Applied optimizations (via API, stored in internal DB):
  - `custom_instructions`: domain-specific fact extraction prompt
  - `max_tokens`: 1000 (down from upstream default 2000)

### Sync from Upstream

When mem0ai/mem0 releases a new version, follow this procedure:

```bash
# 0. Pre-flight checks
git status --short           # MUST be clean before rebase
git stash                    # stash any uncommitted work
git branch pre-rebase-$(date +%Y%m%d)  # backup branch

# 1. Fetch upstream
git remote add upstream https://github.com/mem0ai/mem0.git 2>/dev/null  # idempotent
git fetch upstream --tags

# 2. Identify target version
git log --oneline upstream/main -5   # or: git tag -l 'v*' | sort -V | tail -5

# 3. Replay our overlay on top of upstream
git rebase upstream/main             # or: git rebase <tag>

# 4. Resolve conflicts — see Conflict Resolution Rules table below
#    For config.py: keep openai_base_url fields
#    For platform.py: keep entire file (we own it)
#    For other overlay files: inspect upstream diff, merge carefully

# 5. Rebuild and test
cd openmemory/api && podman build -t localhost/mem0:latest -f Dockerfile.standalone .
cd ../.. && bash stop.sh && bash start.sh
# Run integration test: python3 /tmp/mem0-test.py verify

# 6. Check for dependency drift
diff openmemory/api/requirements.prod.txt <(git show upstream/main:openmemory/api/requirements.txt 2>/dev/null)

# 7. If .env needs new vars, update ~/.local/share/mem0/.env
# 8. Force-push to origin (since rebase rewrites history)
git push --force-with-lease origin main

# 9. Cleanup backup branch (optional)
# git branch -d pre-rebase-$(date +%Y%m%d)
```

### Conflict Resolution Rules

| Scenario | Resolution |
|----------|------------|
| Upstream adds fields to `LLMConfig`/`EmbedderConfig` | Keep upstream additions + keep our `openai_base_url` field |
| Upstream modifies `get_default_configuration()` in `config.py` | Keep our env-var-driven version — upstream may replace with hardcoded defaults |
| Upstream modifies `memories.py` data typing | Re-apply our `Union[str, List[Dict]]` on top of upstream version |
| Upstream touches `platform.py` | Unlikely — we own this file entirely. If upstream adds their own, merge routes |
| Upstream changes `Dockerfile.standalone` or `entrypoint.sh` | These likely don't exist upstream — always keep ours |
| Upstream changes `requirements.prod.txt` | Merge: keep our additions (faiss-cpu), adopt upstream dependency bumps |
| Upstream changes `memory.py` config flow | Re-apply our `get_memory_client()` on top of upstream version |
| Upstream changes `categorization.py` | Keep our lazy-init `_get_client()` pattern — survives missing OPENAI_API_KEY |
| Upstream changes `.dockerignore` | Keep our version — includes `.env` exclusion for security |
| Dependency drift in `requirements.txt` vs `requirements.prod.txt` | Periodically diff; adopt upstream security patches into our minimal dep file |

### Agent Auto-Management

When working in this project, the agent should:

1. **Before any changes**: Check if upstream has new releases (`git fetch upstream --tags && git tag -l 'v*' | sort -V | tail -3`). If a new version exists, notify the user and offer to sync.
2. **When adding customizations**: Update this manifest table. New files must be listed here to survive rebase.
3. **After rebase**: Always rebuild the container and verify with a smoke test (ping + add + search + delete).
4. **Preserve**: Never remove `openai_base_url` from `LLMConfig`/`EmbedderConfig` — this is our critical bugfix.
5. **Run configuration**: After rebuild, re-apply runtime config via API if DB was reset:
   - `PUT /api/v1/config/openmemory` with `custom_instructions`
   - `PUT /api/v1/config/mem0/llm` with `max_tokens: 1000` + `openai_base_url`
   - Re-add personal memories from backup if needed

### Overlay Commits (base reference)

```
0ab4fc16 fix: add openai_base_url to LLMConfig and EmbedderConfig
e6dc1e6d feat: switch to embeddinggemma:300m-qat-q4_0 (239MB, 80% recall)
0c18e199 refactor: type data field properly as Union[str, List[Dict[str, str]]] instead of Any
a11a35c8 fix: support MemoryClient 2.x (org_id/project_id in ping, flexible add payload)
eb41d3e5 feat: self-hosted mem0 server with Ollama embeddings and FAISS
```

These commits represent the full overlay. Use `git rebase upstream/main` to replay them.

---

## Project Overview

**Mem0** ("mem-zero") is an intelligent memory layer for AI agents and assistants. It provides persistent, personalized memory via both a hosted platform API and self-hosted open-source SDKs.

- **Repository**: https://github.com/mem0ai/mem0
- **Documentation**: https://docs.mem0.ai
- **License**: Apache-2.0

## Repository Structure

This is a **polyglot monorepo** containing Python and TypeScript packages, CLIs, servers, plugins, documentation, and evaluation tooling.

### Key Directories

| Directory | Description |
|-----------|-------------|
| `mem0/` | Core Python SDK (`mem0ai` on PyPI) — memory, LLMs, embeddings, vector stores, graphs, rerankers |
| `mem0-ts/` | TypeScript SDK (`mem0ai` on npm) — client + OSS memory |
| `cli/python/` | Python CLI (`mem0-cli` on PyPI) — Typer-based, entry point `mem0` |
| `cli/node/` | Node CLI (`@mem0/cli` on npm) — Commander-based, entry point `mem0` |
| `vercel-ai-sdk/` | `@mem0/vercel-ai-provider` — Vercel AI SDK memory provider |
| `openclaw/` | `@mem0/openclaw-mem0` — OpenClaw plugin for Claude Code / AI editors |
| `server/` | FastAPI REST server for self-hosted Mem0 (Docker: FastAPI + PostgreSQL/pgvector + Neo4j) |
| `openmemory/` | Self-hosted memory platform — `api/` (FastAPI + Alembic + MCP server) and `ui/` (Next.js 15 + React 19) |
| `mem0-plugin/` | AI editor plugins (Claude Code, Cursor, Codex) — MCP server connection, lifecycle hooks, skills |
| `skills/` | Claude Code skill definitions. Reference skills (SDK knowledge, always-on): `mem0/`, `mem0-cli/`, `mem0-vercel-ai-sdk/`. Pipeline skills (run on demand): `mem0-integrate/`, `mem0-test-integration/` |
| `docs/` | Documentation site (Mintlify) |
| `tests/` | Python SDK tests (pytest) |
| `evaluation/` | Benchmarking framework — LOCOMO evals, experiment runner, score generation |
| `examples/` | Sample projects — demo apps, Chrome extension, multi-agent patterns |
| `cookbooks/` | Jupyter notebooks — customer support chatbot, AutoGen integration |
| `pr-reviews/` | Pull request review materials |
| `scripts/` | Repo-wide utility scripts (e.g., `check-llms-txt-coverage.py` for docs/llms.txt sync) |

### Core Package Dependencies

```
mem0 (Python SDK)          mem0-ts (TypeScript SDK)
├── mem0/memory/           ├── src/client/        (MemoryClient — hosted)
├── mem0/llms/             └── src/oss/           (Memory — self-hosted)
├── mem0/embeddings/           ├── src/llms/
├── mem0/vector_stores/        ├── src/embeddings/
├── mem0/graphs/               ├── src/vector_stores/
└── mem0/reranker/             └── src/graphs/

cli/python/ ──▶ mem0ai (optional, for OSS mode)
cli/node/   ──▶ mem0ai (npm, for API calls)
vercel-ai-sdk/ ──▶ ai, @ai-sdk/* providers
openclaw/   ──▶ mem0ai (npm)
```

## Development Setup

### Requirements

- **Python**: 3.9+ (3.10+ for CLI)
- **Node.js**: v18+ (v20 or v22 recommended)
- **pnpm**: v10+ (`npm install -g pnpm@10`) — used for all TypeScript packages
- **Hatch**: Python build/environment tool (`pip install hatch`)
- **Docker**: Required for `server/` and `openmemory/` development

### Initial Setup

```bash
# Python SDK
hatch shell dev_py_3_11           # creates environment with all deps
pre-commit install                # install git hooks

# TypeScript packages
cd mem0-ts && pnpm install        # TS SDK
cd cli/node && pnpm install       # Node CLI
cd vercel-ai-sdk && pnpm install  # Vercel AI provider
cd openclaw && pnpm install       # OpenClaw plugin
```

## Build, Lint, and Test Commands

### Python SDK (`mem0/`)

```bash
# Environment setup (uses Hatch)
hatch shell dev_py_3_11           # or dev_py_3_9, dev_py_3_10, dev_py_3_12

# Linting and formatting
make lint                          # ruff check
make format                        # ruff format
make sort                          # isort mem0/

# Tests
make test                          # pytest tests/
make test-py-3.9                   # test specific Python version (3.9–3.12)

# Build and publish
make build                         # hatch build
make publish                       # hatch publish
```

- **Python:** 3.9, 3.10, 3.11, 3.12
- **Linter/formatter:** Ruff (line length **120**)
- **Import sorting:** isort (`profile = "black"`)
- **Test framework:** pytest (with pytest-mock, pytest-asyncio)
- **Pre-commit hooks:** ruff + isort — run `pre-commit install` before committing

### TypeScript SDK (`mem0-ts/`)

```bash
cd mem0-ts
pnpm install
pnpm run build                     # tsup
pnpm run test                      # jest (all tests)
pnpm run test:unit                 # jest --coverage (unit tests only)
pnpm run test:integration          # jest (integration tests, needs MEM0_API_KEY)
pnpm run test:ci                   # jest --coverage --ci (CI mode)
pnpm run test:watch                # jest watch mode
```

- **Node:** 20, 22 (CI-tested)
- **Build:** tsup (CJS + ESM)
- **Test:** jest
- **Formatter:** prettier

### Python CLI (`cli/python/`)

```bash
cd cli/python
pip install -e ".[dev]"            # dev install with ruff + pytest
ruff check .                       # lint
ruff format .                      # format
pytest                             # test
hatch build                        # build
```

- **Python:** 3.10+ (not 3.9)
- **Linter/formatter:** Ruff (line length **100** — different from root SDK)
- **Ruff rules:** E, F, I, W, UP, B, SIM, RUF (ignores E501, B008 for Typer patterns, SIM108)
- **Framework:** Typer + Rich + httpx
- **Entry point:** `mem0 = "mem0_cli.app:main"`
- **Source layout:** `src/mem0_cli/`
- **Optional dependency:** `mem0ai` (for OSS mode, via `[oss]` extra)

### Node CLI (`cli/node/`)

```bash
cd cli/node
pnpm install
pnpm run build                     # tsup
pnpm run lint                      # biome check src/
pnpm run lint:fix                  # biome check --write src/
pnpm run typecheck                 # tsc --noEmit
pnpm run test                      # vitest run
pnpm run test:watch                # vitest (watch mode)
pnpm run dev                       # tsx src/index.ts (development)
```

- **Node:** 18+ required
- **Build:** tsup (ESM)
- **Linter:** Biome (not ESLint, not Ruff)
- **Test:** vitest (not jest)
- **Framework:** Commander + Chalk + ora + cli-table3

### Vercel AI SDK Provider (`vercel-ai-sdk/`)

```bash
cd vercel-ai-sdk
pnpm install
pnpm run build                     # tsup
pnpm run lint                      # eslint
pnpm run type-check                # tsc --noEmit
pnpm run prettier-check            # prettier --check
pnpm run test                      # jest
pnpm run test:edge                 # vitest (edge runtime)
pnpm run test:node                 # vitest (node runtime)
```

- **Build:** tsup (CJS + ESM)
- **Lint:** ESLint + Prettier
- **Test:** jest + vitest (edge/node configs)

### OpenClaw Plugin (`openclaw/`)

```bash
cd openclaw
pnpm install
pnpm run build                     # tsup
pnpm run test                      # vitest run
```

- **Build:** tsup (ESM)
- **Test:** vitest (with Codecov in CI)
- **Plugin manifest:** `openclaw.plugin.json`

### Server (`server/`)

```bash
# Docker production build
cd server
make build                         # docker build -t mem0-api-server .
make run_local                     # docker run -p 8000:8000 with .env

# Docker Compose development (FastAPI + PostgreSQL/pgvector + Neo4j)
cd server
docker-compose up                  # starts all 3 services
# mem0 API: localhost:8888
# PostgreSQL: localhost:8432
# Neo4j HTTP: localhost:8474, Bolt: localhost:8687
```

- **Framework:** FastAPI with uvicorn (auto-reload in dev)
- **Services:** PostgreSQL with pgvector, Neo4j 5.x with APOC plugin
- **Hot reload:** Dev Dockerfile mounts `server/` and `mem0/` for live changes

### OpenMemory (`openmemory/`)

```bash
# Full stack via Docker Compose
cd openmemory
docker-compose up
# Qdrant: localhost:6333
# API (MCP): localhost:8765
# UI: localhost:3000

# Individual development
cd openmemory/api && uvicorn main:app --reload       # FastAPI backend
cd openmemory/ui && npm run dev                       # Next.js frontend

# Tests
cd openmemory/api && pytest tests/                   # API tests (e.g., test_mcp_server.py)

# Fork overlay regression tests (no DB, no container, no mock server)
cd openmemory/api && pytest tests/unit/test_overlay.py --noconftest -v
```

- **API:** FastAPI + Alembic (DB migrations) + MCP server (Model Context Protocol)
- **UI:** Next.js 15, React 19, Radix UI, Redux Toolkit, TailwindCSS, Recharts
- **Vector store:** Qdrant

### Documentation (`docs/`)

```bash
make docs                          # or: cd docs && mintlify dev
```

- **Framework:** Mintlify
- **API spec:** `docs/openapi.json`
- **Structure:** `api-reference/`, `open-source/`, `platform/`, `integrations/`, `cookbooks/`, `core-concepts/`

### Evaluation (`evaluation/`)

```bash
cd evaluation
make run-mem0-add                  # Run mem0 add experiments
make run-mem0-search               # Run mem0 search experiments
make run-mem0-plus-add             # With graph memory
make run-mem0-plus-search          # With graph memory
make run-rag                       # RAG baseline
make run-full-context              # Full context baseline
make run-langmem                   # LangMem comparison
make run-openai                    # OpenAI comparison
```

## Core APIs

### Python

| Function / Class | Purpose | Import |
|-----------------|---------|--------|
| `Memory` | Self-hosted memory (sync) | `from mem0 import Memory` |
| `AsyncMemory` | Self-hosted memory (async) | `from mem0 import AsyncMemory` |
| `MemoryClient` | Hosted platform client (sync) | `from mem0 import MemoryClient` |
| `AsyncMemoryClient` | Hosted platform client (async) | `from mem0 import AsyncMemoryClient` |

**Key `Memory` / `MemoryClient` methods:**

| Method | Purpose |
|--------|---------|
| `add(messages, *, user_id, agent_id, run_id, metadata)` | Store a new memory |
| `search(query, *, user_id, agent_id, run_id, limit, filters)` | Search memories |
| `get(memory_id)` | Retrieve a single memory by ID |
| `get_all(*, user_id, agent_id, run_id, limit)` | List all memories |
| `update(memory_id, data)` | Update a memory |
| `delete(memory_id)` | Delete a memory |
| `delete_all(*, user_id, agent_id, run_id)` | Delete all memories |
| `history(memory_id)` | Get change history for a memory |

### TypeScript

| Export | Purpose | Import |
|--------|---------|--------|
| `MemoryClient` | Hosted platform client | `import { MemoryClient } from 'mem0ai'` |
| `Memory` | Self-hosted OSS memory | `import { Memory } from 'mem0ai/oss'` |

## Import Patterns

### Python

| What | Import |
|------|--------|
| Core memory classes | `from mem0 import Memory, AsyncMemory` |
| Platform client | `from mem0 import MemoryClient, AsyncMemoryClient` |
| Configuration | `from mem0.configs.base import MemoryConfig` |
| LLM providers | `from mem0.llms.<provider> import <ProviderLLM>` |
| Embedding providers | `from mem0.embeddings.<provider> import <ProviderEmbedding>` |
| Vector store providers | `from mem0.vector_stores.<provider> import <ProviderVectorStore>` |

### TypeScript

| What | Import |
|------|--------|
| Hosted client | `import { MemoryClient } from 'mem0ai'` |
| OSS memory | `import { Memory } from 'mem0ai/oss'` |
| Specific providers (OSS) | `import { OpenAIEmbedding } from 'mem0ai/oss'` |

## Coding Standards

### File Naming Conventions

- **Python source files:** `snake_case.py` (e.g., `azure_openai.py`, `cohere_reranker.py`)
- **Python test files:** `test_<module>.py` (e.g., `test_memory.py`, `test_main.py`)
- **TypeScript source files:** `snake_case.ts` (e.g., `azure_ai_search.ts`)
- **TypeScript test files:** `<module>.test.ts` (e.g., `memory.test.ts`)
- **Config/manifest files:** `kebab-case` (e.g., `openclaw.plugin.json`, `jest.config.js`)

### Python Conventions

- **Provider pattern:** All providers (LLMs, embeddings, vector stores, graphs, rerankers) inherit from a `base.py` abstract class in their directory. Config classes live in `configs.py`.
- **Pydantic v2** for all data models and configuration.
- **Ruff** is the single linting and formatting tool — no black, no flake8.
  - Root SDK: line length **120**
  - Python CLI: line length **100** with extended rule set (UP, B, SIM, RUF)
- **isort** with `profile = "black"` for import sorting.
- Ruff excludes `openmemory/` from root config.

### TypeScript Conventions

- **Build:** tsup across all packages.
- **Package manager:** pnpm everywhere (no npm, no yarn).
- **TypeScript strict mode** across all packages.
- **Linting varies by package:**

| Package | Linter | Formatter | Test Framework |
|---------|--------|-----------|---------------|
| `mem0-ts/` | — | Prettier | jest |
| `cli/node/` | Biome | Biome | vitest |
| `vercel-ai-sdk/` | ESLint | Prettier | jest + vitest |
| `openclaw/` | — | — | vitest |

### Type Checking

Always run type checking after modifying TypeScript code:

```bash
cd <package> && pnpm run typecheck    # or: tsc --noEmit
```

## Architecture

### Provider Pattern

The SDK uses a consistent plugin architecture across 5 categories. Each category has a `base.py` abstract class and concrete provider implementations:

| Category | Examples |
|----------|---------|
| **LLMs** | OpenAI, Anthropic, AWS Bedrock, Azure OpenAI, Gemini, Groq, Ollama, Together, DeepSeek, vLLM, LiteLLM, LM Studio, xAI |
| **Vector Stores** | Qdrant, Pinecone, Chroma, Weaviate, Milvus, MongoDB, Redis, Elasticsearch, pgvector, Supabase, Faiss, S3 Vectors |
| **Embeddings** | OpenAI, Azure OpenAI, Gemini, HuggingFace, FastEmbed, Together, AWS Bedrock, Ollama, Vertex AI |
| **Graph Stores** | Neo4j, Memgraph, Kuzu, Apache AGE |
| **Rerankers** | Cohere, HuggingFace, LLM-based, Sentence Transformer, Zero Entropy |

### Two Usage Modes

Self-hosted `Memory` / `AsyncMemory` classes and hosted-platform `MemoryClient` — both in Python and TypeScript.

### Graph Memory

Optional layer on top of vector memory for relationship-aware retrieval. Configured via the `graph` section of `MemoryConfig`.

### MCP Integration

Model Context Protocol support in multiple places:

- **Remote:** MCP server at `mcp.mem0.ai`
- **Local:** MCP server in `openmemory/api/` (FastAPI-based)
- **Plugin:** MCP tools in `mem0-plugin/` — `add_memory`, `search_memories`, `get_memories`, `get_memory`, `update_memory`, `delete_memory`, `delete_all_memories`, `delete_entities`, `list_entities`

### Plugin & Skills System

- `mem0-plugin/` provides integrations for Claude Code, Cursor, and Codex via MCP server connections and lifecycle hooks for automatic memory capture.
- `skills/` contains structured skill definitions for AI agents, split into two categories:
  - **Reference skills** (always-on SDK knowledge): `mem0` (Python + TS SDKs, framework integrations), `mem0-cli` (terminal workflows), `mem0-vercel-ai-sdk` (Vercel AI provider).
  - **Pipeline skills** (run on demand): `mem0-integrate` wires Mem0 into an existing repo via a TDD pipeline; `mem0-test-integration` verifies what the integrator produced on the same branch. The two are loosely coupled via `.mem0-integration/` artifacts.

### Adding a New Provider

To add a new LLM, embedding, vector store, or reranker provider:

1. Create `mem0/<category>/<provider_name>.py`
2. Inherit from the abstract base class in `mem0/<category>/base.py`
3. Add configuration to `mem0/<category>/configs.py` (if the category uses one)
4. Register the provider in `mem0/<category>/__init__.py`
5. Add tests in `tests/<category>/<provider_name>/`
6. Add any new dependencies to the appropriate optional group in `pyproject.toml` (never to core `dependencies`)
7. Follow the exact pattern of existing providers in the same category — match method signatures, error handling, and config structure

## CI/CD

### CI Workflows (automated testing)

| Workflow | File | Triggers | Tests |
|----------|------|----------|-------|
| Python SDK | `ci.yml` | Push to main, PRs on `mem0/`, `tests/`, `pyproject.toml` | Ruff lint + pytest on Python 3.10, 3.11, 3.12 |
| TypeScript SDK | `ts-sdk-ci.yml` | Push to main, PRs on `mem0-ts/` | Prettier + build + jest on Node 20, 22 |
| Python CLI | `cli-python-ci.yml` | Push to `cli/python/`, PRs, manual | Ruff lint + pytest + hatch build on Python 3.10, 3.11, 3.12 |
| Node CLI | `cli-node-ci.yml` | Push to `cli/node/`, PRs, manual | Biome lint + tsc + vitest + tsup build on Node 20, 22 |
| OpenClaw | `openclaw-checks.yml` | Push to `openclaw/`, PRs, manual | tsc + vitest (with Codecov) + tsup build on Node 20, 22 |

### CD Workflows (automated publishing)

| Workflow | File | Tag Prefix | Target |
|----------|------|------------|--------|
| Python SDK | `cd.yml` | `v*` | PyPI (`mem0ai`) |
| TypeScript SDK | `ts-sdk-cd.yml` | `ts-v*` | npm (`mem0ai`) |
| Python CLI | `cli-python-cd.yml` | `cli-v*` | PyPI (`mem0-cli`) |
| Node CLI | `cli-node-cd.yml` | `cli-node-v*` | npm (`@mem0/cli`) |
| Vercel AI SDK | `vercel-ai-cd.yml` | `vercel-ai-v*` | npm (`@mem0/vercel-ai-provider`) |
| OpenClaw | `openclaw-cd.yml` | `openclaw-v*` | npm (`@mem0/openclaw-mem0`) |

- All publishing uses **OIDC trusted publishing** — no tokens or secrets required.
- First publish of a new npm package must be done manually; OIDC works for subsequent versions.

### Utility Workflows

| Workflow | File | Purpose |
|----------|------|---------|
| Issue Labeler | `issue-labeler.yml` | Automatic issue labeling |
| Stale Bot | `stale.yml` | Marks stale issues and PRs |
| llms.txt Check | `docs-llms-txt-check.yml` | Blocks PRs touching `docs/**/*.mdx` when `docs/llms.txt` is out of sync. Fix locally with `python scripts/check-llms-txt-coverage.py --write`. |

## Task Completion Guidelines

These guidelines outline typical artifacts for different task types. Use judgment to adapt based on scope and context.

### Bug Fixes

1. **Unit tests**: Add tests that would fail without the fix (regression tests)
2. **Implementation**: Fix the bug
3. **Manual verification**: Run the relevant test suite to confirm the fix
4. **Lint**: Run the appropriate linter for the package you modified

### New Features

1. **Implementation**: Build the feature following existing patterns
2. **Unit tests**: Comprehensive test coverage for new functionality
3. **Documentation**: Update relevant docs in `docs/` for public APIs
4. **Examples**: Add usage examples if the feature introduces new user-facing behavior
5. **llms.txt**: Any new `.mdx` page under `docs/` must be linked in `docs/llms.txt` with a scope tag (`[Platform]` / `[OSS]` / `[Both]`) and a `Use when ...` description. The `docs-llms-txt-check.yml` workflow runs on every PR that touches docs and **fails the check** if the index is out of sync. To fix: run `python scripts/check-llms-txt-coverage.py --write` locally to scaffold placeholders under `## Unclassified - needs triage`, then replace the `[TODO: ...]` tags, rewrite descriptions as `Use when ...`, move entries into the right section, and delete the triage heading when empty.

### New Provider (LLM / Embedding / Vector Store / Reranker)

1. **Implementation**: Follow the "Adding a New Provider" steps above
2. **Tests**: Add unit tests matching the pattern of existing providers
3. **Configuration**: Add to the appropriate `configs.py` and `__init__.py`
4. **Dependencies**: Add to the correct optional group in `pyproject.toml`
5. **Documentation**: Add an integration guide in `docs/integrations/`

### Refactoring / Internal Changes

- Unit tests for any changed behavior
- No documentation needed for internal-only changes
- Ensure all existing tests still pass

### When to Deviate

These are guidelines, not rigid rules. Adjust based on:

- **Scope**: Trivial fixes (typos, comments) may not need tests
- **Visibility**: Internal changes may not need documentation
- **Context**: Some changes span multiple categories — use judgment

When uncertain about expected artifacts, ask for clarification.

## Contributing Guidelines

### Workflow

1. Fork and clone the repository.
2. Create a feature branch from `main` (e.g., `feature/my-new-feature`).
3. Make your changes — add tests, docs, and examples as appropriate.
4. Run linting and tests for every package you modified (see commands above).
5. Run `pre-commit install` on first setup — hooks run ruff + isort automatically.
6. Commit with a clear message following [Conventional Commits](https://www.conventionalcommits.org/) (e.g., `feat:`, `fix:`, `docs:`, `refactor:`).
7. Push and open a Pull Request against `main`.

### Pull Request Requirements

Every PR must follow the repo's PR template (`.github/PULL_REQUEST_TEMPLATE.md`):

1. **Linked Issue** — Reference the issue with `Closes #<number>`. If no issue exists, create one first or explain why in the description.
2. **Description** — Explain what the PR does and why it's needed.
3. **Type of Change** — Check the appropriate box:
   - Bug fix / New feature / Breaking change / Refactor / Documentation update
4. **Breaking Changes** — If applicable, describe what breaks and the migration path.
5. **Test Coverage** — Check what applies:
   - Added/updated unit tests
   - Added/updated integration tests
   - Tested manually (describe how)
   - No tests needed (explain why)
6. **Checklist** — All must be checked before merge:
   - [ ] Code follows the project's style guidelines
   - [ ] Self-review performed
   - [ ] Tests added that prove the fix/feature works
   - [ ] New and existing tests pass locally
   - [ ] Documentation updated if needed

### PR Description Template

```markdown
## Linked Issue

Closes #<!-- issue number -->

## Description

<!-- What does this PR do? Why is it needed? -->

## Type of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)
- [ ] Refactor (no functional changes)
- [ ] Documentation update

## Breaking Changes

N/A

## Test Coverage

- [ ] I added/updated unit tests
- [ ] I added/updated integration tests
- [ ] I tested manually (describe below)
- [ ] No tests needed (explain why)

## Checklist

- [ ] My code follows the project's style guidelines
- [ ] I have performed a self-review of my code
- [ ] I have added tests that prove my fix/feature works
- [ ] New and existing tests pass locally
- [ ] I have updated documentation if needed
```

### General Rules

- Follow existing code patterns — don't introduce new frameworks or abstractions without discussion.
- Version bumps go in `pyproject.toml` (Python) or `package.json` (TypeScript).
- For `server/` and `openmemory/` work, use Docker Compose for local development.
- Do NOT use `pip` or `conda` for dependency management — use `hatch` (see `docs/contributing/development.mdx`).

### Contributing Guides

| Task | Guide |
|------|-------|
| Code contributions | `docs/contributing/development.mdx` |
| Documentation contributions | `docs/contributing/documentation.mdx` |
| PR template | `.github/PULL_REQUEST_TEMPLATE.md` |
| Bug reports | `.github/ISSUE_TEMPLATE/bug_report.yml` |
| Feature requests | `.github/ISSUE_TEMPLATE/feature_request.yml` |
| Documentation issues | `.github/ISSUE_TEMPLATE/documentation_issue.yml` |

## Do NOT

- Modify CI/CD workflows without explicit approval.
- Add new Python dependencies to the core `dependencies` list in `pyproject.toml` without discussion — use optional dependency groups instead.
- Commit `.env` files, API keys, or credentials.
- Skip pre-commit hooks.
- Use npm or yarn in TypeScript packages — this repo uses pnpm exclusively.
- Use `require()` for imports in TypeScript — use ES module `import` syntax.
- Mix up linter configs: root Python SDK uses line-length 120, Python CLI uses 100, Node CLI uses Biome (not ESLint/Ruff).
- Modify `openmemory/` database migrations without understanding the Alembic migration chain.
- Change public APIs without updating documentation in `docs/`.
