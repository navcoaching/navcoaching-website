"""Configuration.

Two layers:
* Environment / `.env` — secrets (API keys) and the data directory. Secrets are
  never written to disk by the app, never returned by the API and never logged.
* `settings.json` inside the data directory — non-secret, UI-editable settings
  (provider choice, privacy consents, retrieval thresholds, language).
"""
from __future__ import annotations

import json
import os
import threading
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from urllib.parse import urlparse

_LOCK = threading.RLock()


def _load_dotenv(path: Path) -> None:
    """Minimal .env loader (no external dependency). Existing env vars win."""
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


_load_dotenv(Path(os.environ.get("NAV_ENV_FILE", ".env")))


def data_dir() -> Path:
    d = Path(os.environ.get("NAV_DATA_DIR", "data")).resolve()
    d.mkdir(parents=True, exist_ok=True)
    return d


def secret(name: str) -> str | None:
    """Read a secret from the environment only."""
    value = os.environ.get(name)
    return value or None


LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}


def is_local_url(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    return host in LOCAL_HOSTS or host.endswith(".localhost")


@dataclass
class Settings:
    # --- AI model -----------------------------------------------------------
    # none | ollama | openai_compat | anthropic
    llm_provider: str = "none"
    ollama_url: str = "http://localhost:11434"
    ollama_model: str = "qwen2.5:7b-instruct"
    openai_compat_url: str = "http://localhost:1234/v1"
    openai_compat_model: str = "local-model"
    anthropic_model: str = "claude-opus-5-5"
    llm_verify_claims: bool = True  # second-pass support check by the model
    # --- Embeddings ---------------------------------------------------------
    # hash (built-in, offline, lexical) | ollama | fastembed
    embedding_provider: str = "hash"
    ollama_embedding_model: str = "bge-m3"
    fastembed_model: str = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
    # --- Privacy --------------------------------------------------------------
    # Explicit consent before any library text goes to a non-local model.
    allow_external_llm: bool = False
    # Separate consent for client (trainee) data to a non-local model.
    allow_client_data_external: bool = False
    # Allow one-off model downloads (e.g. fastembed weights). Never sends data.
    allow_model_download: bool = False
    # --- Retrieval ------------------------------------------------------------
    top_k: int = 8
    min_concept_coverage: float = 0.5
    min_vector_similarity: float = 0.35  # used only with semantic embedders
    # --- UI -------------------------------------------------------------------
    language: str = "ar"
    extra: dict = field(default_factory=dict)

    # -- helpers --
    def llm_endpoint(self) -> str | None:
        if self.llm_provider == "ollama":
            return self.ollama_url
        if self.llm_provider == "openai_compat":
            return self.openai_compat_url
        if self.llm_provider == "anthropic":
            return "https://api.anthropic.com"
        return None

    def llm_is_external(self) -> bool:
        ep = self.llm_endpoint()
        return bool(ep) and not is_local_url(ep)

    def public_dict(self) -> dict:
        d = asdict(self)
        d["llm_is_external"] = self.llm_is_external()
        d["secrets"] = {
            "ANTHROPIC_API_KEY": "configured" if secret("ANTHROPIC_API_KEY") else "not set",
            "OPENAI_COMPAT_API_KEY": "configured" if secret("OPENAI_COMPAT_API_KEY") else "not set",
        }
        d["data_dir"] = str(data_dir())
        return d


_cached: Settings | None = None


def _settings_path() -> Path:
    return data_dir() / "settings.json"


def get_settings() -> Settings:
    global _cached
    with _LOCK:
        if _cached is not None:
            return _cached
        s = Settings()
        p = _settings_path()
        if p.is_file():
            try:
                stored = json.loads(p.read_text(encoding="utf-8"))
                names = {f.name for f in fields(Settings)}
                for k, v in stored.items():
                    if k in names:
                        setattr(s, k, v)
            except (OSError, ValueError):
                pass
        _cached = s
        return s


ALLOWED_PROVIDERS = {"none", "ollama", "openai_compat", "anthropic"}
ALLOWED_EMBEDDERS = {"hash", "ollama", "fastembed"}


def update_settings(changes: dict) -> Settings:
    global _cached
    with _LOCK:
        s = get_settings()
        names = {f.name for f in fields(Settings)}
        for k, v in changes.items():
            if k not in names or k == "extra":
                continue
            if k == "llm_provider" and v not in ALLOWED_PROVIDERS:
                raise ValueError(f"unknown provider {v}")
            if k == "embedding_provider" and v not in ALLOWED_EMBEDDERS:
                raise ValueError(f"unknown embedding provider {v}")
            current = getattr(s, k)
            if isinstance(current, bool):
                v = bool(v)
            elif isinstance(current, int) and not isinstance(current, bool):
                v = int(v)
            elif isinstance(current, float):
                v = float(v)
            setattr(s, k, v)
        _settings_path().write_text(json.dumps(asdict(s), ensure_ascii=False, indent=2), encoding="utf-8")
        _cached = s
        return s


def reset_settings_cache() -> None:
    global _cached
    with _LOCK:
        _cached = None
