"""Tests for tools/pdf_to_text.py — the PDF -> text syllabus-seed helper.

These exercise the extraction logic against a hand-built, text-bearing PDF.
They skip automatically if `pypdf` is not importable, so they don't force the
dependency on every environment (the tool itself pulls it in via `uv run`).
"""

import importlib.util
import sys
from pathlib import Path

import pytest

pytest.importorskip("pypdf", reason="pypdf not installed; pdf_to_text needs it")

TOOLS = Path(__file__).resolve().parent.parent / "tools"


def _load_tool():
    """Import tools/pdf_to_text.py as a module."""
    spec = importlib.util.spec_from_file_location("pdf_to_text", TOOLS / "pdf_to_text.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _make_pdf(path: Path, text: str) -> None:
    """Write a minimal single-page PDF containing `text` as extractable text."""
    content = f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET".encode("latin-1")
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    pdf = b"%PDF-1.4\n"
    offsets = []
    for i, obj in enumerate(objs, start=1):
        offsets.append(len(pdf))
        pdf += b"%d 0 obj\n" % i + obj + b"\nendobj\n"
    xref_pos = len(pdf)
    pdf += b"xref\n0 %d\n" % (len(objs) + 1)
    pdf += b"0000000000 65535 f \n"
    for off in offsets:
        pdf += b"%010d 00000 n \n" % off
    pdf += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF" % (len(objs) + 1, xref_pos)
    path.write_bytes(pdf)


def test_extract_text_reads_pdf_content(tmp_path):
    tool = _load_tool()
    pdf = tmp_path / "cv.pdf"
    _make_pdf(pdf, "Senior ML Engineer skills Python PyTorch SQL")

    text = tool.extract_text(pdf)
    assert "Senior ML Engineer" in text
    assert "PyTorch" in text


def test_per_file_output_writes_txt(tmp_path, monkeypatch):
    tool = _load_tool()
    pdf = tmp_path / "resume.pdf"
    _make_pdf(pdf, "Data scientist with statistics background")

    monkeypatch.setattr(sys, "argv", ["pdf_to_text.py", str(pdf)])
    rc = tool.main()
    assert rc == 0

    out = pdf.with_suffix(".txt")
    assert out.is_file(), "expected a .txt next to the PDF"
    body = out.read_text(encoding="utf-8")
    assert "Data scientist" in body


def test_combined_output_merges_pdfs(tmp_path, monkeypatch):
    tool = _load_tool()
    a = tmp_path / "cv.pdf"
    b = tmp_path / "jd.pdf"
    _make_pdf(a, "Candidate knows Kubernetes")
    _make_pdf(b, "Role requires distributed systems")
    combined = tmp_path / "seed.txt"

    monkeypatch.setattr(sys, "argv", ["pdf_to_text.py", str(a), str(b), "-o", str(combined)])
    rc = tool.main()
    assert rc == 0

    body = combined.read_text(encoding="utf-8")
    assert "Kubernetes" in body
    assert "distributed systems" in body
    # Each source is labelled by filename in the combined file.
    assert "# cv.pdf" in body
    assert "# jd.pdf" in body


def test_rejects_non_pdf(tmp_path, monkeypatch):
    tool = _load_tool()
    txt = tmp_path / "notes.txt"
    txt.write_text("just text", encoding="utf-8")

    monkeypatch.setattr(sys, "argv", ["pdf_to_text.py", str(txt)])
    assert tool.main() == 1


def test_rejects_missing_file(tmp_path, monkeypatch):
    tool = _load_tool()
    monkeypatch.setattr(sys, "argv", ["pdf_to_text.py", str(tmp_path / "ghost.pdf")])
    assert tool.main() == 1
