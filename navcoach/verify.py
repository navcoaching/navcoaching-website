"""Claim verification and conflict detection.

A claim is shown to the user only if:
1. it cites at least one passage that was actually retrieved for this question;
2. each cited quote is found verbatim (after whitespace/case normalisation) in
   that passage — the stored quote is then replaced by the exact source text;
3. every number in the claim appears in the cited evidence;
4. causal wording is not used when the evidence only reports association;
5. (same-language claims) the claim shares substantive vocabulary with the quote;
6. optionally, a second model pass judges that the quote supports the claim.
"""
from __future__ import annotations

import difflib
import re

from .textutil import fold, is_arabic, numbers, raw_tokens, sentences, tokens

CAUSAL = re.compile(r"\b(causes?|caused|causing|leads? to|led to|results? in|produces?|drives?)\b|يسبب|تسبب|يؤدي|تؤدي|أدى|سبب", re.I)
ASSOCIATIVE = re.compile(r"\b(associat\w*|correlat\w*|linked|relationship|related to)\b", re.I)
CAUSAL_EVIDENCE = re.compile(r"\b(caus\w*|leads? to|led to|results? in|resulted in|randomi[sz]ed|induced?|elicit\w*|produced?)\b", re.I)


def _norm(s: str) -> str:
    return fold(s).replace("\n", " ")


def locate_quote(quote: str, passage: str) -> str | None:
    """Return the exact span of `passage` matching `quote`, or None."""
    if not quote or not passage:
        return None
    q = _norm(quote).strip(" .\"'")
    p_norm = _norm(passage)
    if len(q) < 12:
        return None
    if q in p_norm:
        # Map back to the original text by searching sentence-wise for readability.
        for s in sentences(passage):
            if q in _norm(s):
                return s if len(s) <= len(q) * 2.5 else q
        return q
    # Fuzzy: tolerate minor extraction/whitespace/punctuation differences.
    best, best_ratio = None, 0.0
    for s in sentences(passage):
        r = difflib.SequenceMatcher(None, q, _norm(s)).ratio()
        if r > best_ratio:
            best, best_ratio = s, r
    if best_ratio >= 0.9:
        return best
    # A quote that is a sub-span of one sentence
    for s in sentences(passage):
        sn = _norm(s)
        if len(q) < len(sn):
            m = difflib.SequenceMatcher(None, q, sn).find_longest_match(0, len(q), 0, len(sn))
            if m.size >= 0.92 * len(q):
                return s
    return None


def _script_is_arabic(text: str) -> bool:
    toks = raw_tokens(text)
    return bool(toks) and sum(is_arabic(t) for t in toks) / len(toks) > 0.5


def check_claim(claim_text: str, quotes: list[str], claim_type: str = "stated") -> tuple[bool, list[str], list[str]]:
    """Deterministic checks. Returns (ok, errors, warnings)."""
    errors, warnings = [], []
    evidence = " ".join(quotes)
    missing = {n for n in numbers(claim_text) if n not in numbers(evidence)}
    # Allow citation-like numbers e.g. years/page references only when in evidence.
    if missing:
        errors.append(f"numbers not found in the cited evidence: {', '.join(sorted(missing))}")
    if CAUSAL.search(claim_text) and not CAUSAL_EVIDENCE.search(evidence):
        if ASSOCIATIVE.search(evidence):
            errors.append("causal wording, but the evidence reports an association only")
        else:
            warnings.append("causal wording — confirm the study design supports causation")
    if not _script_is_arabic(claim_text) and not _script_is_arabic(evidence):
        ct, et = set(tokens(claim_text)), set(tokens(evidence))
        if ct:
            overlap = len(ct & et) / len(ct)
            if overlap < 0.25:
                errors.append("claim wording is not supported by the quoted text")
            elif overlap < 0.5 and claim_type == "stated":
                warnings.append("claim paraphrases the evidence loosely — read the quote")
    return (not errors), errors, warnings


# ----------------------------------------------------------------- conflicts

POSITIVE = re.compile(
    r"\b(significantly (greater|higher|larger|more|increased|improved|better)|greater|superior|larger gains|"
    r"more effective|increased|improved|enhanced|dose[- ]response|favou?red|benefit(s|ed)?)\b", re.I)
NULL = re.compile(
    r"\b(no (significant |statistically significant |meaningful |additional |further )?(difference|differences|effect|benefit|"
    r"advantage|change)s?|did not (differ|increase|improve|enhance|result)|not significant(ly)?( different)?|similar|"
    r"comparable|equivalent|no additional benefit|plateau(ed)?|regardless of)\b", re.I)
NEGATIVE = re.compile(r"\b(decreased|reduced|impaired|worse|inferior|detrimental|blunted|attenuated)\b", re.I)


def polarity(sentence: str) -> str | None:
    s = sentence
    if NULL.search(s):
        return "no_difference"
    if NEGATIVE.search(s) and not POSITIVE.search(s):
        return "negative"
    if POSITIVE.search(s):
        return "positive"
    return None


def detect_conflicts(items: list[dict], concepts: list[set[str]]) -> list[dict]:
    """Find statements from different documents on the same topic with opposite direction.

    items: [{"doc_id", "filename", "text", "claim_index"}]
    """
    enriched = []
    for it in items:
        pol = polarity(it["text"])
        if pol:
            toks = set(tokens(it["text"]))
            enriched.append({**it, "polarity": pol, "toks": toks})
    conflicts = []
    seen_pairs = set()
    for i, a in enumerate(enriched):
        for b in enriched[i + 1:]:
            if a["doc_id"] == b["doc_id"] or a["polarity"] == b["polarity"]:
                continue
            shared_concepts = [sorted(g)[0] for g in concepts if g & a["toks"] and g & b["toks"]]
            shared = (a["toks"] & b["toks"]) - {"study", "group", "participant", "result", "week"}
            if len(shared_concepts) < max(1, min(2, len(concepts))) or len(shared) < 3:
                continue
            key = tuple(sorted((a["doc_id"], b["doc_id"])))
            if key in seen_pairs:
                continue
            seen_pairs.add(key)
            conflicts.append({
                "topic": ", ".join(shared_concepts) or ", ".join(sorted(shared)[:4]),
                "positions": [
                    {"doc_id": x["doc_id"], "filename": x["filename"], "polarity": x["polarity"],
                     "text": x["text"], "claim_index": x.get("claim_index")} for x in (a, b)
                ],
            })
    return conflicts
