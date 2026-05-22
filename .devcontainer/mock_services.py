"""
Mock services for local development without real LLM/embedder devices.

Provides:
  - Ollama-compatible embedding API on :11434
  - Returns deterministic fake embeddings (hash-based vectors)
  - Ollama /api/tags and /api/pull stubs
  - OpenAI-compatible chat completions stub (returns canned response)
"""

import hashlib
from typing import Optional

import numpy as np
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="Mock Services")

EMBEDDING_DIM = 768


def _hash_vector(text: str, dim: int = EMBEDDING_DIM) -> list[float]:
    """Generate a deterministic unit vector from text via SHA-256 iterated hashing."""
    rng = np.random.RandomState(hash(text) & 0xFFFFFFFF)
    vec = rng.randn(dim).astype(np.float32)
    vec = np.nan_to_num(vec, nan=0.0, posinf=0.0, neginf=0.0)
    norm = np.linalg.norm(vec)
    if norm > 0:
        vec = vec / norm
    return vec.tolist()


# ── Ollama stubs ──────────────────────────────────────────────────────────────


@app.get("/api/tags")
async def ollama_tags():
    return {
        "models": [
            {"name": "embeddinggemma:300m-qat-q4_0", "size": 239000000, "digest": "mock"},
            {"name": "nomic-embed-text", "size": 274000000, "digest": "mock"},
        ]
    }


@app.post("/api/pull")
async def ollama_pull(request: Request):
    body = await request.json()
    name = body.get("name", "unknown")
    return {"status": f"mock: {name} already available"}


@app.post("/api/embeddings")
async def ollama_embeddings(request: Request):
    body = await request.json()
    prompt = body.get("prompt", "")
    if isinstance(prompt, list):
        prompt = " ".join(prompt)
    embedding = _hash_vector(prompt)
    return {"embedding": embedding}


@app.post("/api/embed")
async def ollama_embed(request: Request):
    body = await request.json()
    input_texts = body.get("input", "")
    if isinstance(input_texts, str):
        input_texts = [input_texts]
    embeddings = [_hash_vector(t) for t in input_texts]
    return {"model": body.get("model", "mock"), "embeddings": embeddings}


@app.post("/api/generate")
async def ollama_generate(request: Request):
    return {
        "model": "mock",
        "response": "Mock response for development.",
        "done": True,
    }


# ── OpenAI-compatible stubs (on same port, /v1 path) ─────────────────────────


@app.post("/v1/chat/completions")
async def openai_chat(request: Request):
    return {
        "id": "mock-chatcmpl",
        "object": "chat.completion",
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": '[{"memory": "Mock extracted fact", "event": "MOCK"}]',
                },
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20},
    }


@app.post("/v1/embeddings")
async def openai_embeddings(request: Request):
    body = await request.json()
    input_texts = body.get("input", "")
    if isinstance(input_texts, str):
        input_texts = [input_texts]
    data = [
        {"object": "embedding", "index": i, "embedding": _hash_vector(t)}
        for i, t in enumerate(input_texts)
    ]
    return {
        "object": "list",
        "data": data,
        "model": body.get("model", "mock"),
        "usage": {"prompt_tokens": sum(len(t.split()) for t in input_texts), "total_tokens": 0},
    }
