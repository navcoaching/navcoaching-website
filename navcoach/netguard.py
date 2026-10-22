"""Network guard: blocks every outbound connection that is not loopback.

The assistant must never browse the internet or fetch external sources. This
module installs a Python audit hook that intercepts DNS lookups and socket
connections. Non-local traffic is refused unless the caller is inside an
``allow_external(reason)`` block, which is used *only* by an LLM/embedding
provider the user explicitly configured and consented to in Settings.

Every attempt (allowed or blocked) is recorded so tests and the UI can prove
that a question was answered without external contact.
"""
from __future__ import annotations

import contextlib
import contextvars
import ipaddress
import sys
import threading
import time

_allowed_reason: contextvars.ContextVar[str | None] = contextvars.ContextVar("nav_external", default=None)
_installed = False
_enabled = True
_lock = threading.Lock()
_log: list[dict] = []


class ExternalNetworkBlocked(PermissionError):
    pass


def _is_local_host(host) -> bool:
    if host is None:
        return True
    if isinstance(host, bytes):
        host = host.decode(errors="ignore")
    host = str(host).strip("[]").lower()
    if host in ("", "localhost") or host.endswith(".localhost"):
        return True
    try:
        ip = ipaddress.ip_address(host.split("%")[0])
        return ip.is_loopback or ip.is_unspecified
    except ValueError:
        return False


def _record(kind: str, host, allowed: bool, reason: str | None) -> None:
    with _lock:
        _log.append({"t": time.time(), "kind": kind, "host": str(host), "allowed": allowed, "reason": reason})
        if len(_log) > 500:
            del _log[:100]


def _hook(event: str, args) -> None:
    if not _enabled:
        return
    host = None
    if event == "socket.getaddrinfo":
        host = args[0]
    elif event == "socket.connect":
        addr = args[1]
        if isinstance(addr, tuple) and addr:
            host = addr[0]
        else:  # AF_UNIX paths etc. are local
            return
    else:
        return
    if _is_local_host(host):
        return
    reason = _allowed_reason.get()
    if reason:
        _record(event, host, True, reason)
        return
    _record(event, host, False, None)
    raise ExternalNetworkBlocked(f"External network access blocked ({event})")


def install() -> None:
    global _installed
    if not _installed:
        sys.addaudithook(_hook)
        _installed = True


def set_enabled(value: bool) -> None:
    """Only for diagnostics; the app always runs with the guard enabled."""
    global _enabled
    _enabled = value


@contextlib.contextmanager
def allow_external(reason: str):
    token = _allowed_reason.set(reason)
    try:
        yield
    finally:
        _allowed_reason.reset(token)


def attempts(since: float = 0.0) -> list[dict]:
    with _lock:
        return [a for a in _log if a["t"] >= since]


def clear_log() -> None:
    with _lock:
        _log.clear()
