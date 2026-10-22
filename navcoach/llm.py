"""Swappable language-model providers.

* ``none``          — no model; answers are composed only of verbatim quotes (extractive mode).
* ``ollama``        — local Ollama server (default local option).
* ``openai_compat`` — any OpenAI-compatible server (LM Studio, llama.cpp, vLLM ...).
* ``anthropic``     — Claude API (external; requires explicit consent in Settings).

The model is used to *read and organise* retrieved passages. It is never a
source: its output is parsed as JSON and every claim is checked by
:mod:`navcoach.verify` against the retrieved text before it is shown.
"""
from __future__ import annotations

import json
import re

from . import netguard
from .config import Settings, is_local_url, secret


class LLMUnavailable(RuntimeError):
    pass


class PrivacyBlocked(PermissionError):
    pass


class LLM:
    name = "base"
    external = False

    def complete_json(self, system: str, user: str, max_tokens: int = 4000) -> dict:
        text = self.complete(system, user, max_tokens)
        return parse_json(text)

    def complete(self, system: str, user: str, max_tokens: int = 4000) -> str:  # pragma: no cover
        raise NotImplementedError


def parse_json(text: str) -> dict:
    text = (text or "").strip()
    m = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.S)
    if m:
        text = m.group(1)
    else:
        start, end = text.find("{"), text.rfind("}")
        if start >= 0 and end > start:
            text = text[start:end + 1]
    try:
        out = json.loads(text)
    except ValueError as exc:
        raise LLMUnavailable("model did not return valid JSON") from exc
    if not isinstance(out, dict):
        raise LLMUnavailable("model did not return a JSON object")
    return out


class _Ctx:
    def __init__(self, external: bool, reason: str):
        self.cm = netguard.allow_external(reason) if external else None

    def __enter__(self):
        if self.cm:
            self.cm.__enter__()

    def __exit__(self, *exc):
        if self.cm:
            return self.cm.__exit__(*exc)
        return False


class OllamaLLM(LLM):
    def __init__(self, url: str, model: str):
        self.url, self.model = url.rstrip("/"), model
        self.name = f"ollama:{model}"
        self.external = not is_local_url(url)

    def complete(self, system: str, user: str, max_tokens: int = 4000) -> str:
        import httpx2 as httpx
        payload = {"model": self.model, "stream": False, "format": "json",
                   "options": {"temperature": 0, "num_predict": max_tokens},
                   "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
        try:
            with _Ctx(self.external, "llm:ollama"), httpx.Client(timeout=600) as c:
                r = c.post(f"{self.url}/api/chat", json=payload)
                r.raise_for_status()
                return r.json()["message"]["content"]
        except netguard.ExternalNetworkBlocked:
            raise
        except Exception as exc:
            raise LLMUnavailable(f"Ollama not reachable ({type(exc).__name__})") from exc


class OpenAICompatLLM(LLM):
    def __init__(self, url: str, model: str):
        self.url, self.model = url.rstrip("/"), model
        self.name = f"openai_compat:{model}"
        self.external = not is_local_url(url)

    def complete(self, system: str, user: str, max_tokens: int = 4000) -> str:
        import httpx2 as httpx
        headers = {}
        key = secret("OPENAI_COMPAT_API_KEY")
        if key:
            headers["Authorization"] = f"Bearer {key}"
        payload = {"model": self.model, "temperature": 0, "max_tokens": max_tokens,
                   "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
        try:
            with _Ctx(self.external, "llm:openai_compat"), httpx.Client(timeout=600) as c:
                r = c.post(f"{self.url}/chat/completions", json=payload, headers=headers)
                r.raise_for_status()
                return r.json()["choices"][0]["message"]["content"]
        except netguard.ExternalNetworkBlocked:
            raise
        except Exception as exc:
            raise LLMUnavailable(f"model server not reachable ({type(exc).__name__})") from exc


class AnthropicLLM(LLM):
    external = True

    def __init__(self, model: str):
        self.model = model
        self.name = f"anthropic:{model}"
        if not secret("ANTHROPIC_API_KEY"):
            raise LLMUnavailable("ANTHROPIC_API_KEY is not set in .env")

    def complete(self, system: str, user: str, max_tokens: int = 4000) -> str:
        try:
            import anthropic
        except ImportError as exc:
            raise LLMUnavailable("anthropic package not installed: pip install anthropic") from exc
        client = anthropic.Anthropic(api_key=secret("ANTHROPIC_API_KEY"))
        try:
            with _Ctx(True, "llm:anthropic"):
                response = client.beta.messages.create(
                    model=self.model,
                    max_tokens=max(max_tokens, 16000),
                    betas=["server-side-fallback-2026-07-01"],
                    fallbacks="default",
                    output_config={"effort": "medium"},
                    system=system,
                    messages=[{"role": "user", "content": user}],
                )
        except anthropic.APIStatusError as exc:
            raise LLMUnavailable(f"Claude API error (HTTP {exc.status_code})") from exc
        except anthropic.APIConnectionError as exc:
            raise LLMUnavailable("Claude API not reachable") from exc
        if response.stop_reason == "refusal":
            raise LLMUnavailable("the model declined this request")
        return "".join(b.text for b in response.content if b.type == "text")


def get_llm(settings: Settings, purpose: str = "library") -> LLM | None:
    """Return the configured model, enforcing privacy consents.

    purpose: 'library' (scientific passages) or 'client' (trainee data).
    Returns None in extractive mode.
    """
    p = settings.llm_provider
    if p == "none":
        return None
    if p == "ollama":
        llm: LLM = OllamaLLM(settings.ollama_url, settings.ollama_model)
    elif p == "openai_compat":
        llm = OpenAICompatLLM(settings.openai_compat_url, settings.openai_compat_model)
    elif p == "anthropic":
        llm = AnthropicLLM(settings.anthropic_model)
    else:
        raise LLMUnavailable(f"unknown provider {p}")
    if llm.external:
        if not settings.allow_external_llm:
            raise PrivacyBlocked("external model selected but sending passages to it is not allowed in Settings")
        if purpose == "client" and not settings.allow_client_data_external:
            raise PrivacyBlocked("sending client data to an external model is not allowed in Settings")
    return llm
