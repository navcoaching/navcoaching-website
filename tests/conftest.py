import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


@pytest.fixture()
def env(tmp_path, monkeypatch):
    """Fresh, isolated data directory for every test."""
    data = tmp_path / "data"
    monkeypatch.setenv("NAV_DATA_DIR", str(data))
    from navcoach import config, db, embeddings, index, netguard
    config.reset_settings_cache()
    db.reset_init_cache()
    embeddings._cache.clear()
    index.vector_cache.invalidate()
    netguard.install()
    netguard.clear_log()
    files = tmp_path / "files"
    files.mkdir()
    yield {"data": data, "files": files}
    config.reset_settings_cache()
    db.reset_init_cache()


class FakeLLM:
    """Scripted model used to test the verification layer deterministically."""
    name = "fake"
    external = False

    def __init__(self, responder):
        self.responder = responder
        self.calls = []

    def complete_json(self, system, user, max_tokens=4000):
        self.calls.append({"system": system, "user": user})
        out = self.responder(system, user, len(self.calls))
        return out if isinstance(out, dict) else json.loads(out)


@pytest.fixture()
def fake_llm():
    return FakeLLM
