"""Whole-file reading and the final answer check."""
from navcoach import db, ingest, rag
from navcoach.index import Hit


def _add_text(env, name, text):
    p = env["files"] / name
    p.write_text(text, encoding="utf-8")
    return ingest.add_file(name, p.read_bytes(), sync=True)


FILLER = ("Warm-up routines differ between coaches and athletes. Hydration status was recorded before each visit. "
          "Equipment was calibrated by the laboratory staff according to the manufacturer manual. ")


def _long_manual(phases: int, every: int = 20) -> str:
    paras = []
    for i in range(1, phases * every + 1):
        if i % every == 0:
            paras.append(f"In phase {i // every}, resistance training sessions were performed three times per week.")
        else:
            paras.append(f"Section {i}. " + FILLER)
    return "\n\n".join(paras)


def test_whole_file_is_read_and_every_statement_counted(env):
    d = _add_text(env, "manual.md", _long_manual(15))
    assert d["chunk_count"] > 40
    r = rag.ask("How many resistance training sessions per week?", lang="en")
    assert r["status"] == "answered"
    v = r["verification"]
    # Every passage of the file was read, not only the top search candidates.
    assert v["scan"]["passages"] == d["chunk_count"]
    assert v["files_scanned"] == ["manual.md"]
    # All 15 phase statements found (the old top-k path kept at most 3 passages per file).
    assert v["supporting_statements"] == 15
    assert v["verdict"] == "verified"
    assert v["values"] and v["values"][0]["unit"] == "times"
    assert v["values"][0]["values"][0]["value"] == "three" and len(v["values"][0]["values"]) == 1
    same = [c for c in r["claims"] if "three times per week" in c["text"]]
    # Repeated statements are shown once, with every other place they occur listed.
    assert len(same) == 1 and len(same[0]["also_stated_in"]) == 14


def test_arabic_sessions_question_reads_whole_file(env):
    d = _add_text(env, "manual.md", _long_manual(5))
    r = rag.ask("كم عدد جلسات تدريب المقاومة في الأسبوع؟", lang="ar")
    assert r["status"] == "answered" and not r.get("untranslated_terms")
    assert r["verification"]["scan"]["passages"] == d["chunk_count"]
    assert r["verification"]["supporting_statements"] == 5


def test_statement_at_the_very_end_of_a_long_file_is_found(env):
    text = "\n\n".join(f"Section {i}. " + FILLER for i in range(400))
    text += "\n\nCreatine monohydrate was supplemented at 5 g per day during the final block."
    d = _add_text(env, "long.md", text)
    r = rag.ask("What creatine dose per day?", lang="en")
    assert r["status"] == "answered"
    assert r["verification"]["scan"]["passages"] == d["chunk_count"]
    assert any("5 g per day" in c["text"] for c in r["claims"])


def test_differing_values_across_files_are_reported_not_resolved(env):
    _add_text(env, "a.md", "Resistance training sessions were performed three times per week in study A.")
    _add_text(env, "b.md", "Resistance training sessions were performed two times per week in study B.")
    r = rag.ask("How many resistance training sessions per week?", lang="ar")
    assert r["status"] == "answered"
    v = r["verification"]
    assert v["verdict"] == "verified_with_differences"
    assert "times" in v["differing_values"]
    vals = {x["value"] for x in v["values"][0]["values"]}
    assert vals == {"three", "two"}
    files = {c["filename"] for c in r["citations"].values()}
    assert files == {"a.md", "b.md"}
    assert "قُرئت الملفات كاملة" in v["summary"][0]


def test_final_check_removes_claim_whose_quote_is_not_in_the_file(env):
    h = Hit(chunk_id="x-00000", doc_id="x", text="Training was performed three days per week.", page=1,
            printed_page=None, location=None, section=None, quality="ok", flags=[], filename="x.md",
            title=None, authors=None, year=None, doc_type=None)
    good = {"text": "Training was performed three days per week.", "type": "quote", "citations": ["E1"],
            "quotes": {"E1": "Training was performed three days per week."}, "warnings": []}
    bad = {"text": "Training was performed five days per week.", "type": "stated", "citations": ["E1"],
           "quotes": {"E1": "Training was performed five days per week."}, "warnings": []}
    scan = {"files": 1, "passages": 1, "pages": 1, "unreadable_pages": 0, "filenames": ["x.md"]}
    keep, rejected, rep = rag._final_check([good, bad], {"E1": h}, [], [], scan, "en")
    assert keep == [good]
    assert rejected and "final check" in rejected[0]["reasons"][0]
    assert rep["claims_removed"] == 1


def test_document_scope_reads_only_that_file(env):
    a = _add_text(env, "a.md", "Resistance training sessions were performed three times per week.")
    _add_text(env, "b.md", "Resistance training sessions were performed two times per week.")
    r = rag.ask("How many resistance training sessions per week?", lang="en", doc_ids=[a["id"]])
    assert r["verification"]["files_scanned"] == ["a.md"]
    assert r["verification"]["verdict"] == "verified"


def test_fuzzy_quote_match_never_changes_numbers_or_negation():
    from navcoach.verify import locate_quote
    src = "Training was performed three days per week. Protein intake did not differ between groups."
    assert locate_quote("Training was performed three days per week", src)
    assert locate_quote("Training was performed five days per week", src) is None
    assert locate_quote("Protein intake did differ between groups", src) is None
