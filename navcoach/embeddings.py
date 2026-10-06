"""Embedding providers (swappable).

* ``hash``      — built-in, fully offline, zero download. Signed feature hashing of
                  stemmed words, bigrams and character n-grams. It is *lexical*
                  similarity (robust to morphology/typos), not true semantics.
* ``ollama``    — local Ollama server (e.g. ``bge-m3``: multilingual, semantic).
* ``fastembed`` — local ONNX model (optional ``pip install fastembed``); the model
                  weights are downloaded once if "allow model download" is on.

Changing provider requires an index rebuild (the app detects the mismatch).
"""
from __future__ import annotations

import hashlib
import math

import numpy as np

from . import netguard
from .config import Settings, is_local_url
from .textutil import fold, tokens


class Embedder:
    name = "base"
    semantic = False

    def embed(self, texts: list[str]) -> np.ndarray:  # pragma: no cover - interface
        raise NotImplementedError


class HashEmbedder(Embedder):
    name = "hash-v1"
    semantic = False

    def __init__(self, dim: int = 2048):
        self.dim = dim

    def _features(self, text: str) -> dict[str, float]:
        toks = tokens(text)
        feats: dict[str, float] = {}
        for t in toks:
            feats["w:" + t] = feats.get("w:" + t, 0) + 1.0
        for a, b in zip(toks, toks[1:]):
            k = f"b:{a}_{b}"
            feats[k] = feats.get(k, 0) + 0.7
        for t in set(toks):
            if len(t) >= 5:
                for i in range(len(t) - 3):
                    k = "c:" + t[i:i + 4]
                    feats[k] = feats.get(k, 0) + 0.25
        return feats

    def embed(self, texts: list[str]) -> np.ndarray:
        out = np.zeros((len(texts), self.dim), dtype=np.float32)
        for row, text in enumerate(texts):
            for f, w in self._features(text).items():
                h = int.from_bytes(hashlib.blake2b(f.encode(), digest_size=8).digest(), "little")
                idx = h % self.dim
                sign = 1.0 if (h >> 63) & 1 else -1.0
                out[row, idx] += sign * (1.0 + math.log(w)) if w >= 1 else sign * w
            n = np.linalg.norm(out[row])
            if n > 0:
                out[row] /= n
        return out


class OllamaEmbedder(Embedder):
    semantic = True

    def __init__(self, url: str, model: str, allow_external: bool):
        self.url = url.rstrip("/")
        self.model = model
        self.name = f"ollama:{model}"
        self.external = not is_local_url(url)
        if self.external and not allow_external:
            raise PermissionError("Ollama embedding URL is not local and external use is not allowed in Settings")

    def embed(self, texts: list[str]) -> np.ndarray:
        import httpx2 as httpx

        vecs = []
        ctx = netguard.allow_external("embeddings:ollama") if self.external else _null()
        with ctx, httpx.Client(timeout=120) as client:
            for i in range(0, len(texts), 32):
                r = client.post(f"{self.url}/api/embed", json={"model": self.model, "input": texts[i:i + 32]})
                r.raise_for_status()
                vecs.extend(r.json()["embeddings"])
        arr = np.asarray(vecs, dtype=np.float32)
        arr /= np.maximum(np.linalg.norm(arr, axis=1, keepdims=True), 1e-9)
        return arr


class FastEmbedEmbedder(Embedder):
    semantic = True

    def __init__(self, model: str, allow_download: bool):
        try:
            from fastembed import TextEmbedding
        except ImportError as exc:
            raise RuntimeError("fastembed is not installed: pip install fastembed") from exc
        self.name = f"fastembed:{model}"
        ctx = netguard.allow_external("model-download:fastembed") if allow_download else _null()
        with ctx:
            self._model = TextEmbedding(model_name=model)

    def embed(self, texts: list[str]) -> np.ndarray:
        arr = np.asarray(list(self._model.embed(texts)), dtype=np.float32)
        arr /= np.maximum(np.linalg.norm(arr, axis=1, keepdims=True), 1e-9)
        return arr


class _null:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


_cache: dict[tuple, Embedder] = {}


def get_embedder(settings: Settings) -> Embedder:
    key = (settings.embedding_provider, settings.ollama_url, settings.ollama_embedding_model,
           settings.fastembed_model, settings.allow_external_llm, settings.allow_model_download)
    if key in _cache:
        return _cache[key]
    if settings.embedding_provider == "ollama":
        emb: Embedder = OllamaEmbedder(settings.ollama_url, settings.ollama_embedding_model, settings.allow_external_llm)
    elif settings.embedding_provider == "fastembed":
        emb = FastEmbedEmbedder(settings.fastembed_model, settings.allow_model_download)
    else:
        emb = HashEmbedder()
    _cache[key] = emb
    return emb


def normalise_for_embedding(text: str) -> str:
    return fold(text)[:4000]
