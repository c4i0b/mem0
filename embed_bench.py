#!/usr/bin/env python3
"""
Gemini Embedding Model Benchmark

Compares Google Gemini embedding models for retrieval quality.
Tests semantic search (EN) and cross-language retrieval (PT→EN).

Usage:
    python3 embed_bench.py                          # default models & dims
    python3 embed_bench.py --models gemini-embedding-2 --dims 768 1536
    python3 embed_bench.py --detail                  # show top-3 per query

Requires: google-genai, GOOGLE_API_KEY env var
Runs inside the mem0 container or any env with google-genai installed.
"""

import argparse
import math
import os
import time
from typing import Optional

from google import genai
from google.genai import types


ALL_MODELS = [
    "models/gemini-embedding-001",
    "models/gemini-embedding-2",
    "models/gemini-embedding-2-preview",
]

ALL_DIMS = [768, 1536, 3072]

MEMORIES = [
    "I am a vegetarian who loves Italian food, especially pasta carbonara and margherita pizza.",
    "My dog Luna is a golden retriever and she is 3 years old.",
    "I work at Google as a machine learning engineer on the Search team in Mountain View.",
    "I play acoustic guitar and my favorite band is Radiohead. I saw them live in 2019.",
    "I am learning Japanese because I want to travel to Tokyo next spring for cherry blossom season.",
    "I prefer running in the morning and do yoga every evening before bed.",
]

EN_QUERIES = [
    ("EN", "What kind of food does this person like?", [0]),
    ("EN", "Does this person have any pets?", [1]),
    ("EN", "What does this person do for work?", [2]),
    ("EN", "What musical instrument do they play?", [3]),
    ("EN", "Where do they want to travel?", [4]),
    ("EN", "What is this person's favorite band?", [3]),
    ("EN", "What is the name of their dog?", [1]),
    ("EN", "What is their dietary restriction?", [0]),
]

PT_QUERIES = [
    ("PT", "O que essa pessoa gosta de comer?", [0]),
    ("PT", "Onde essa pessoa trabalha?", [2]),
    ("PT", "Que instrumento musical ela toca?", [3]),
    ("PT", "Qual e a rotina de exercicios dessa pessoa?", [5]),
    ("PT", "Onde ela quer viajar na primavera?", [4]),
    ("PT", "A pessoa tem cachorro?", [1]),
]

ALL_QUERIES = EN_QUERIES + PT_QUERIES


def cosine_sim(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na > 0 and nb > 0 else 0.0


def embed_one(client: genai.Client, model: str, text: str, dims: int) -> list[float]:
    cfg = types.EmbedContentConfig(output_dimensionality=dims)
    resp = client.models.embed_content(model=model, contents=[text], config=cfg)
    return resp.embeddings[0].values


def embed_batch_safe(
    client: genai.Client, model: str, texts: list[str], dims: int
) -> list[list[float]]:
    cfg = types.EmbedContentConfig(output_dimensionality=dims)
    resp = client.models.embed_content(model=model, contents=texts, config=cfg)
    if len(resp.embeddings) == len(texts):
        return [e.values for e in resp.embeddings]
    return [embed_one(client, model, t, dims) for t in texts]


def run_benchmark(
    models: list[str],
    dims_list: list[int],
    detail: bool = False,
) -> list[dict]:
    client = genai.Client(api_key=os.environ["GOOGLE_API_KEY"])
    results = []

    print(
        f"\n{'MODEL':<28} {'DIMS':>4}  {'TIME':>7}  "
        f"{'EN':>7}  {'PT':>7}  {'TOTAL':>7}  {'AVG_SIM':>8}"
    )
    print("-" * 95)

    for model in models:
        short = model.replace("models/", "")
        for dims in dims_list:
            t0 = time.time()

            try:
                mem_vecs = embed_batch_safe(client, model, MEMORIES, dims)
            except Exception as e:
                print(f"{short:<28} {dims:>4}  err: {str(e)[:60]}")
                continue

            if len(mem_vecs) != len(MEMORIES):
                print(
                    f"{short:<28} {dims:>4}  batch err: "
                    f"got {len(mem_vecs)} expected {len(MEMORIES)}"
                )
                continue

            en_ok = 0
            pt_ok = 0
            all_sims = []
            details = []

            for lang, q, expected in ALL_QUERIES:
                qv = embed_one(client, model, q, dims)
                sims = sorted(
                    [(i, cosine_sim(qv, mv)) for i, mv in enumerate(mem_vecs)],
                    key=lambda x: x[1],
                    reverse=True,
                )
                top_idx = sims[0][0]
                all_sims.append(sims[0][1])
                hit = top_idx in expected

                if lang == "EN":
                    if hit:
                        en_ok += 1
                else:
                    if hit:
                        pt_ok += 1

                if detail:
                    details.append((lang, q, expected, hit, sims[:3]))

            elapsed = int((time.time() - t0) * 1000)
            total = en_ok + pt_ok
            total_q = len(EN_QUERIES) + len(PT_QUERIES)
            avg_sim = sum(all_sims) / len(all_sims)

            en_p = en_ok * 100 // len(EN_QUERIES)
            pt_p = pt_ok * 100 // len(PT_QUERIES)
            tot_p = total * 100 // total_q

            print(
                f"{short:<28} {dims:>4}  {elapsed:>6}ms  "
                f"{en_ok}/{len(EN_QUERIES)} {en_p:>3}%  "
                f"{pt_ok}/{len(PT_QUERIES)} {pt_p:>3}%  "
                f"{total}/{total_q} {tot_p:>3}%  {avg_sim:.4f}"
            )

            row = {
                "model": short,
                "dims": dims,
                "time_ms": elapsed,
                "en": f"{en_ok}/{len(EN_QUERIES)}",
                "pt": f"{pt_ok}/{len(PT_QUERIES)}",
                "total": f"{total}/{total_q}",
                "avg_sim": round(avg_sim, 4),
            }
            results.append(row)

            if detail:
                print(f"\n  Details for {short} @ {dims}d:")
                for lang, q, expected, hit, top3 in details:
                    marker = "OK" if hit else "MISS"
                    print(f"  [{lang}] {q:<50} -> {marker}")
                    for rank, (idx, sim) in enumerate(top3):
                        exp_mark = " <--" if idx in expected else ""
                        print(f"       #{rank+1} M{idx} ({sim:.4f}){exp_mark}")
                print()

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Benchmark Gemini embedding models for retrieval quality"
    )
    parser.add_argument(
        "--models",
        nargs="+",
        default=None,
        choices=["gemini-embedding-001", "gemini-embedding-2", "gemini-embedding-2-preview"],
        help="Models to test (default: all 3)",
    )
    parser.add_argument(
        "--dims",
        nargs="+",
        type=int,
        default=None,
        choices=[768, 1024, 1536, 2048, 3072],
        help="Dimensions to test (default: 768 1536 3072)",
    )
    parser.add_argument(
        "--detail",
        action="store_true",
        help="Show top-3 results per query",
    )
    args = parser.parse_args()

    models = (
        [f"models/{m}" for m in args.models]
        if args.models
        else ALL_MODELS
    )
    dims = args.dims if args.dims else ALL_DIMS

    print("=" * 95)
    print("  Gemini Embedding Model Benchmark")
    print("=" * 95)
    print(
        f"  {len(models)} models x {len(dims)} dims = "
        f"{len(models) * len(dims)} configs"
    )
    print(
        f"  {len(MEMORIES)} seed memories, "
        f"{len(EN_QUERIES)} EN queries, "
        f"{len(PT_QUERIES)} PT cross-lang queries"
    )

    run_benchmark(models, dims, detail=args.detail)

    print("\n  EN = English semantic search  |  PT = Portuguese cross-language")
    print("  AVG_SIM = average cosine similarity of top-1 result")
    print()


if __name__ == "__main__":
    main()
