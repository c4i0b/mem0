"""
Regression tests for fork overlay modifications.

These tests protect the critical overlay points that break on upstream rebase:
1. openai_base_url / ollama_base_url fields survive Pydantic model round-trip
2. Config factory builds correct structure from env vars
3. Categorization lazy init survives missing OPENAI_API_KEY
4. Data field typing (Union[str, List[Dict]]) validated via schema

Pure unit tests — no database, no FastAPI app, no mock server needed.
Run: pytest tests/unit/ --noconftest
"""

import os
import pytest


# ---------------------------------------------------------------------------
# 1. Pydantic models: custom fields must survive serialization round-trip
# ---------------------------------------------------------------------------

class TestConfigModelsPreserveFields:
    """If upstream rewrites models and drops openai_base_url/ollama_base_url,
    these fail. This was our most critical bug (config PUT silently dropped fields).
    """

    def test_llm_config_openai_base_url_roundtrip(self):
        from app.routers.config import LLMConfig

        cfg = LLMConfig(
            model="test-model",
            temperature=0.1,
            max_tokens=1000,
            api_key="sk-test",
            openai_base_url="https://custom.api.example.com/v1",
        )
        dumped = cfg.model_dump()
        assert dumped["openai_base_url"] == "https://custom.api.example.com/v1"
        restored = LLMConfig(**dumped)
        assert restored.openai_base_url == "https://custom.api.example.com/v1"

    def test_llm_config_ollama_base_url_roundtrip(self):
        from app.routers.config import LLMConfig

        cfg = LLMConfig(
            model="llama3",
            temperature=0.1,
            max_tokens=2000,
            ollama_base_url="http://host.docker.internal:11434",
        )
        dumped = cfg.model_dump()
        assert dumped["ollama_base_url"] == "http://host.docker.internal:11434"
        restored = LLMConfig(**dumped)
        assert restored.ollama_base_url == "http://host.docker.internal:11434"

    def test_embedder_config_openai_base_url_roundtrip(self):
        from app.routers.config import EmbedderConfig

        cfg = EmbedderConfig(
            model="text-embedding-3-small",
            api_key="sk-test",
            openai_base_url="https://custom.api.example.com/v1",
        )
        dumped = cfg.model_dump()
        assert dumped["openai_base_url"] == "https://custom.api.example.com/v1"
        restored = EmbedderConfig(**dumped)
        assert restored.openai_base_url == "https://custom.api.example.com/v1"

    def test_embedder_config_ollama_base_url_roundtrip(self):
        from app.routers.config import EmbedderConfig

        cfg = EmbedderConfig(
            model="nomic-embed-text",
            ollama_base_url="http://localhost:11434",
        )
        dumped = cfg.model_dump()
        assert dumped["ollama_base_url"] == "http://localhost:11434"

    def test_llm_config_fields_not_missing(self):
        """If upstream adds or removes fields, this catches it."""
        from app.routers.config import LLMConfig

        expected = {
            "model", "temperature", "max_tokens",
            "api_key", "ollama_base_url", "openai_base_url",
        }
        actual = set(LLMConfig.model_fields.keys())
        missing = expected - actual
        assert not missing, f"LLMConfig missing fields: {missing}"

    def test_embedder_config_fields_not_missing(self):
        from app.routers.config import EmbedderConfig

        expected = {
            "model", "api_key", "ollama_base_url", "openai_base_url",
        }
        actual = set(EmbedderConfig.model_fields.keys())
        missing = expected - actual
        assert not missing, f"EmbedderConfig missing fields: {missing}"


# ---------------------------------------------------------------------------
# 2. Config factory: env vars produce correct config structure
# ---------------------------------------------------------------------------

class TestConfigFactory:
    """If upstream changes the config flow or env var names, these fail."""

    def test_faiss_detected_from_env(self, monkeypatch):
        from app.utils.memory import get_default_memory_config

        monkeypatch.setenv("FAISS_PATH", "/data/faiss")
        monkeypatch.setenv("EMBEDDING_DIMS", "768")
        monkeypatch.setenv("LLM_PROVIDER", "openai")
        monkeypatch.setenv("LLM_MODEL", "test-model")
        monkeypatch.setenv("LLM_API_KEY", "test-key")
        monkeypatch.setenv("LLM_BASE_URL", "https://api.test.com/v1")
        monkeypatch.delenv("CHROMA_HOST", raising=False)
        monkeypatch.delenv("QDRANT_HOST", raising=False)

        config = get_default_memory_config()
        assert config["vector_store"]["provider"] == "faiss"
        assert config["vector_store"]["config"]["embedding_model_dims"] == 768

    def test_openai_llm_config_with_base_url(self, monkeypatch):
        from app.utils.memory import get_default_memory_config

        monkeypatch.setenv("FAISS_PATH", "/data/faiss")
        monkeypatch.setenv("LLM_PROVIDER", "openai")
        monkeypatch.setenv("LLM_MODEL", "glm-5-turbo")
        monkeypatch.setenv("LLM_API_KEY", "test-key")
        monkeypatch.setenv("LLM_BASE_URL", "https://api.z.ai/v1")
        monkeypatch.setenv("EMBEDDER_PROVIDER", "ollama")
        monkeypatch.setenv("EMBEDDER_MODEL", "test-embed")

        config = get_default_memory_config()
        llm = config["llm"]
        assert llm["provider"] == "openai"
        assert llm["config"]["model"] == "glm-5-turbo"
        assert llm["config"]["openai_base_url"] == "https://api.z.ai/v1"
        assert llm["config"]["api_key"] == "test-key"

    def test_ollama_llm_config(self, monkeypatch):
        from app.utils.memory import get_default_memory_config

        monkeypatch.setenv("FAISS_PATH", "/data/faiss")
        monkeypatch.setenv("LLM_PROVIDER", "ollama")
        monkeypatch.setenv("LLM_MODEL", "llama3.1:latest")
        monkeypatch.setenv("OLLAMA_BASE_URL", "http://localhost:11434")

        config = get_default_memory_config()
        llm = config["llm"]
        assert llm["provider"] == "ollama"
        assert llm["config"]["model"] == "llama3.1:latest"
        assert llm["config"]["ollama_base_url"] == "http://localhost:11434"

    def test_ollama_embedder_config(self, monkeypatch):
        from app.utils.memory import get_default_memory_config

        monkeypatch.setenv("FAISS_PATH", "/data/faiss")
        monkeypatch.setenv("LLM_PROVIDER", "openai")
        monkeypatch.setenv("LLM_API_KEY", "test-key")
        monkeypatch.setenv("EMBEDDER_PROVIDER", "ollama")
        monkeypatch.setenv("EMBEDDER_MODEL", "embeddinggemma:300m-qat-q4_0")
        monkeypatch.setenv("OLLAMA_BASE_URL", "http://localhost:11434")

        config = get_default_memory_config()
        emb = config["embedder"]
        assert emb["provider"] == "ollama"
        assert emb["config"]["model"] == "embeddinggemma:300m-qat-q4_0"

    def test_env_var_resolution(self, monkeypatch):
        """'env:VAR_NAME' strings must be resolved to actual values."""
        from app.utils.memory import _parse_environment_variables

        monkeypatch.setenv("MY_SECRET_KEY", "resolved-value-123")

        config = {
            "llm": {"config": {"api_key": "env:MY_SECRET_KEY"}},
            "embedder": {"config": {"api_key": "plain-text"}},
        }
        parsed = _parse_environment_variables(config)
        assert parsed["llm"]["config"]["api_key"] == "resolved-value-123"
        assert parsed["embedder"]["config"]["api_key"] == "plain-text"


# ---------------------------------------------------------------------------
# 3. Categorization: lazy init survives missing OPENAI_API_KEY
# ---------------------------------------------------------------------------

class TestCategorizationLazyInit:
    """If upstream reverts to eager init at module level, these will fail."""

    def test_no_crash_without_openai_key(self, monkeypatch):
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)

        import importlib
        import app.utils.categorization as cat_mod
        importlib.reload(cat_mod)
        assert hasattr(cat_mod, "get_categories_for_memory")

    def test_get_client_returns_none_without_key(self, monkeypatch):
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)

        import app.utils.categorization as cat_mod
        cat_mod._openai_client = None
        assert cat_mod._get_client() is None

    def test_get_categories_returns_empty_without_key(self, monkeypatch):
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)

        import app.utils.categorization as cat_mod
        cat_mod._openai_client = None
        assert cat_mod.get_categories_for_memory("test memory text") == []


# ---------------------------------------------------------------------------
# 4. Data field typing: schema accepts Union types
# ---------------------------------------------------------------------------

class TestMemoryDataFieldSchema:
    """Verify the AddMemory schema accepts both string and list payloads.

    Our overlay makes the data field flexible (Union type).
    If upstream changes the schema, this catches it.
    """

    def test_schema_accepts_string_data(self):
        from app.routers.platform import PlatformAddRequest

        msg = PlatformAddRequest(data="Simple string memory", user_id="test-user")
        assert msg.data == "Simple string memory"

    def test_schema_accepts_list_data(self):
        from app.routers.platform import PlatformAddRequest

        msg = PlatformAddRequest(
            data=[
                {"role": "user", "content": "Hello"},
                {"role": "assistant", "content": "Hi there"},
            ],
            user_id="test-user",
        )
        assert isinstance(msg.data, list)
        assert len(msg.data) == 2

    def test_schema_rejects_invalid_data(self):
        from app.routers.platform import PlatformAddRequest
        from pydantic import ValidationError

        with pytest.raises(ValidationError):
            PlatformAddRequest(data=12345, user_id="test-user")
