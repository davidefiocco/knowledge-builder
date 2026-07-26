#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["huggingface_hub"]
# ///
"""Optional offline syllabus extraction.

The plugin builds the syllabus in-editor by default. This standalone script is
useful for batch/headless generation or for piping large inputs (a full CV +
job description) without pasting into Neovim. It prints a JSON object
{"topics": [...]} that matches what `syllabus.lua` expects, so it can be saved
directly to a project's syllabus.json.

Usage:
    HF_TOKEN=... uv run tools/extract_syllabus.py inputs.txt > syllabus.json
    cat cv.txt jd.txt | HF_TOKEN=... uv run tools/extract_syllabus.py -
"""

import argparse
import json
import sys
from pathlib import Path

from huggingface_hub import InferenceClient

DEFAULT_MODEL = "Qwen/Qwen3-Coder-Next"

SYSTEM_PROMPT = """You are a curriculum designer. Given a user's inputs (which \
may include a job description, CV/resume, and free-form goals), produce a \
focused syllabus of the subjects they should master.

Return ONLY a JSON object of this exact shape, no prose, no markdown fences:
{ "topics": [ { "name": "Short topic name", "description": "1-2 sentence scope", "weight": 1.0 } ] }

Rules:
- Between 4 and 10 topics, ordered from foundational to advanced.
- weight is a float 0.5-2.0 reflecting how central the topic is to the goal.
- Topics must be specific and assessable."""


def extract_json(text: str):
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1:
        raise ValueError(f"No JSON object found in model output:\n{text}")
    return json.loads(text[start : end + 1])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="Path to inputs file, or '-' for stdin")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--token", default=None, help="HF token (defaults to $HF_TOKEN)")
    args = parser.parse_args()

    source = sys.stdin.read() if args.input == "-" else Path(args.input).read_text(encoding="utf-8")
    if not source.strip():
        print("No input provided", file=sys.stderr)
        return 1

    client = InferenceClient(token=args.token)
    resp = client.chat_completion(
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"## User inputs\n\n{source}"},
        ],
        model=args.model,
        temperature=0.7,
        max_tokens=1024,
    )
    data = extract_json(resp.choices[0].message.content)
    json.dump(data, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
