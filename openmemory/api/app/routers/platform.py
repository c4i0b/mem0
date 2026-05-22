import logging
from typing import Any, Dict, List, Optional, Union

from app.utils.memory import get_memory_client
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

router = APIRouter(tags=["platform-api"])


class PlatformAddRequest(BaseModel):
    messages: Optional[List[str]] = None
    data: Optional[Union[str, List[Dict[str, str]]]] = None
    user_id: Optional[str] = None
    agent_id: Optional[str] = None
    run_id: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None
    infer: bool = True


class PlatformSearchRequest(BaseModel):
    query: str
    user_id: Optional[str] = None
    agent_id: Optional[str] = None
    run_id: Optional[str] = None
    top_k: int = 10
    threshold: float = 0.1


def _filters(req):
    f = {}
    if getattr(req, "user_id", None):
        f["user_id"] = req.user_id
    if getattr(req, "agent_id", None):
        f["agent_id"] = req.agent_id
    if getattr(req, "run_id", None):
        f["run_id"] = req.run_id
    return f


def _get_client():
    client = get_memory_client()
    if not client:
        raise HTTPException(status_code=503, detail="Memory client unavailable")
    return client


@router.post("/v3/memories/add/")
async def platform_add(request: PlatformAddRequest):
    client = _get_client()
    text = request.data
    if request.messages and not text:
        text = " ".join(request.messages)
    if not text:
        raise HTTPException(status_code=400, detail="No text or messages provided")

    try:
        kwargs = {"infer": request.infer}
        if request.user_id:
            kwargs["user_id"] = request.user_id
        if request.agent_id:
            kwargs["agent_id"] = request.agent_id
        if request.metadata:
            kwargs["metadata"] = request.metadata
        result = client.add(text, **kwargs)
        return {"results": _normalize_add(result)}
    except Exception as e:
        logging.error(f"Platform add failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/v3/memories/search/")
async def platform_search(request: PlatformSearchRequest):
    client = _get_client()
    try:
        result = client.search(
            request.query,
            filters=_filters(request),
            top_k=request.top_k,
            threshold=request.threshold,
        )
        return result
    except Exception as e:
        logging.error(f"Platform search failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/v3/memories/")
@router.get("/v3/memories/")
async def platform_get_all(request: Request):
    client = _get_client()
    body = {}
    try:
        body = await request.json()
    except Exception:
        pass

    filters = {}
    for key in ("user_id", "agent_id", "run_id"):
        val = body.get(key)
        if val:
            filters[key] = val

    try:
        result = client.get_all(filters=filters)
        return {"results": _normalize_get_all(result)}
    except Exception as e:
        logging.error(f"Platform get_all failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/v3/memories/")
async def platform_delete(request: Request):
    client = _get_client()
    body = await request.json()

    memory_id = body.get("memory_id")
    if not memory_id:
        raise HTTPException(status_code=400, detail="memory_id required")

    try:
        client.delete(memory_id)
        return {"message": "Deleted"}
    except Exception as e:
        logging.error(f"Platform delete failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/v1/ping/")
async def platform_ping():
    return {"status": "ok", "org_id": "local", "project_id": "local", "user_email": "hermes@local"}


def _normalize_add(result):
    if isinstance(result, dict) and "results" in result:
        items = result["results"]
    elif isinstance(result, list):
        items = result
    else:
        return []
    out = []
    for item in items:
        if isinstance(item, dict):
            out.append({
                "id": item.get("id", ""),
                "memory": item.get("memory", item.get("content", "")),
                "event": item.get("event", "ADD"),
            })
    return out


def _normalize_get_all(result):
    if isinstance(result, dict) and "results" in result:
        items = result["results"]
    elif isinstance(result, list):
        items = result
    else:
        return []
    out = []
    for item in items:
        if isinstance(item, dict):
            out.append({
                "id": item.get("id", ""),
                "memory": item.get("memory", item.get("content", "")),
                "user_id": item.get("user_id", ""),
                "metadata": item.get("metadata", {}),
                "created_at": item.get("created_at", ""),
                "updated_at": item.get("updated_at", ""),
            })
    return out
