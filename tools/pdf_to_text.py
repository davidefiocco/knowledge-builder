#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pypdf>=4.0"]
# ///
"""Convert PDF(s) into plain-text files usable as a knowledge-builder seed.

The plugin reads syllabus inputs as plain text (a job description, CV, or
free-form goals). PDFs are binary, so convert them first with this helper, then
feed the resulting .txt to `:KB start` (paste its path) or to
`tools/extract_syllabus.py`.

Usage:
    # One PDF -> cv.txt next to it
    uv run tools/pdf_to_text.py cv.pdf

    # Several PDFs, each -> <name>.txt beside the source
    uv run tools/pdf_to_text.py cv.pdf job_description.pdf

    # Write all extracted text into one combined file
    uv run tools/pdf_to_text.py cv.pdf jd.pdf -o combined.txt

    # Print to stdout instead of writing files (pipe into another tool)
    uv run tools/pdf_to_text.py cv.pdf --stdout | uv run tools/extract_syllabus.py -
"""

import argparse
import sys
from pathlib import Path

from pypdf import PdfReader


def extract_text(pdf_path: Path) -> str:
    """Return the concatenated text of every page in the PDF."""
    reader = PdfReader(str(pdf_path))
    parts = []
    for page in reader.pages:
        text = page.extract_text() or ""
        text = text.strip()
        if text:
            parts.append(text)
    return "\n\n".join(parts).strip()


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("pdfs", nargs="+", help="One or more PDF file paths")
    parser.add_argument(
        "-o",
        "--output",
        default=None,
        help="Write all extracted text to this single file (default: one .txt per PDF)",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print extracted text to stdout instead of writing files",
    )
    args = parser.parse_args()

    chunks: list[str] = []
    for raw in args.pdfs:
        path = Path(raw)
        if not path.is_file():
            print(f"error: not a file: {path}", file=sys.stderr)
            return 1
        if path.suffix.lower() != ".pdf":
            print(f"error: not a .pdf: {path}", file=sys.stderr)
            return 1
        try:
            text = extract_text(path)
        except Exception as exc:  # noqa: BLE001 - surface any pypdf failure clearly
            print(f"error: failed to read {path}: {exc}", file=sys.stderr)
            return 1
        if not text:
            print(f"warning: no extractable text in {path} (scanned/image PDF?)", file=sys.stderr)

        if args.stdout or args.output:
            # Label each source so a combined file stays legible.
            chunks.append(f"# {path.name}\n\n{text}")
        else:
            out = path.with_suffix(".txt")
            out.write_text(text, encoding="utf-8")
            print(f"wrote {out} ({len(text)} chars)", file=sys.stderr)

    if args.stdout:
        sys.stdout.write("\n\n".join(chunks) + "\n")
    elif args.output:
        out = Path(args.output)
        out.write_text("\n\n".join(chunks) + "\n", encoding="utf-8")
        print(f"wrote {out} ({sum(len(c) for c in chunks)} chars from {len(args.pdfs)} pdf(s))", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
