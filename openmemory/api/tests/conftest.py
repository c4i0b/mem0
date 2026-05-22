"""
Shared test fixtures for OpenMemory API tests.

All external services (LLM, embedder) are mocked so tests run without
real devices or API keys. Uses httpx ASGITransport for in-process testing.
"""

import os

# Set dummy env vars before any app imports that trigger client initialization
os.environ.setdefault("USER", "test-user")
os.environ.setdefault("API_KEY", "test-key")
os.environ.setdefault("LLM_API_KEY", "test-key")
os.environ.setdefault("LLM_BASE_URL", "http://mock:11434/v1")
os.environ.setdefault("OLLAMA_BASE_URL", "http://mock:11434")
os.environ.setdefault("DATABASE_URL", "sqlite:///./test-openmemory.db")

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from main import app
from app.database import Base, engine, SessionLocal


@pytest.fixture(autouse=True)
def _clean_db():
    """Create all tables before each test, drop after."""
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)
    # Remove test DB file
    for f in ["test-openmemory.db"]:
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass


@pytest_asyncio.fixture
async def client():
    """Async HTTP client wired to the FastAPI app via ASGI transport."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture
def db():
    """Synchronous DB session for direct data setup/assertions."""
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()
