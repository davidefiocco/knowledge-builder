#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pynvim", "huggingface_hub", "pytest"]
# ///
"""Tier 2 (deferred, opt-in) LLM-in-the-loop end-to-end test for knowledge-builder.

This harness drives the plugin's *headless scriptable API* (api.lua) over RPC
from a real (headless) Neovim instance, using two LLM roles:

  * a SIMULATED-USER agent that reads each question the plugin presents and
    produces a realistic answer for a given persona/skill level;
  * a JUDGE agent (LLM-as-judge) that reviews the full transcript and asserts
    the interaction was coherent, on-syllabus, and graded sanely.

It is intentionally gated:
  * marked `@pytest.mark.llm` so default CI can skip it (`pytest -m "not llm"`),
  * skipped automatically unless `HF_TOKEN` is set,
  * skipped unless `pynvim` and a `nvim` binary are available.

Run explicitly with:
    HF_TOKEN=... uv run -m pytest test/test_llm_loop.py -m llm -v
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.llm

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
DEV_INIT = PLUGIN_ROOT / "dev" / "init.lua"

MODEL = os.environ.get("KB_TEST_MODEL", "Qwen/Qwen3-Coder-Next")

USER_PERSONA = (
    "You are simulating a mid-level software engineer taking a knowledge "
    "assessment. Answer each question genuinely at that skill level: mostly "
    "correct, occasionally imperfect. Be concise."
)

JUDGE_RUBRIC = (
    "You are an impartial QA judge reviewing an automated assessment session. "
    "Given the transcript (questions the system asked, the candidate's answers, "
    "and the scores/feedback the system produced), decide whether the system "
    "behaved correctly. Check that: questions are on-topic for the syllabus, "
    "each question is well-formed, and the scores are plausible given the "
    "answers. Respond ONLY with JSON: "
    '{"verdict": "pass" | "fail", "reasons": "..."}'
)


def _require(condition, reason):
    if not condition:
        pytest.skip(reason)


@pytest.fixture(scope="module")
def hf_client():
    _require(os.environ.get("HF_TOKEN"), "HF_TOKEN not set")
    huggingface_hub = pytest.importorskip("huggingface_hub")
    return huggingface_hub.InferenceClient(token=os.environ["HF_TOKEN"])


@pytest.fixture()
def nvim():
    pynvim = pytest.importorskip("pynvim")
    _require(shutil.which("nvim"), "nvim binary not found")

    workspace = tempfile.mkdtemp(prefix="kb-llm-test-")
    env = dict(os.environ, KB_WORKSPACE=workspace)
    child = pynvim.attach(
        "child",
        argv=[
            "nvim",
            "--headless",
            "--embed",
            "-u",
            str(DEV_INIT),
        ],
        env=env,
    )
    try:
        yield child
    finally:
        child.close()
        shutil.rmtree(workspace, ignore_errors=True)


def _lua(nvim, expr):
    """Evaluate a Lua expression that returns a JSON string, decode it."""
    raw = nvim.exec_lua(f"return {expr}")
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode()
    return json.loads(raw) if isinstance(raw, str) else raw


def _ask_user_llm(client, question):
    prompt = f"## Question ({question['kind']})\n{question['prompt']}"
    if question["kind"] == "mcq":
        opts = "\n".join(
            f"{o['number']}. {o['text']}" for o in question.get("payload", {}).get("options", [])
        )
        prompt += f"\n\n## Options\n{opts}\n\nReply with 'Answer: <number>'."
    resp = client.chat_completion(
        messages=[
            {"role": "system", "content": USER_PERSONA},
            {"role": "user", "content": prompt},
        ],
        model=MODEL,
        max_tokens=400,
    )
    return resp.choices[0].message.content


def _judge(client, transcript):
    resp = client.chat_completion(
        messages=[
            {"role": "system", "content": JUDGE_RUBRIC},
            {"role": "user", "content": json.dumps(transcript, indent=2)},
        ],
        model=MODEL,
        temperature=0.1,
        max_tokens=400,
    )
    text = resp.choices[0].message.content
    start = text.find("{")
    end = text.rfind("}")
    return json.loads(text[start : end + 1])


def test_test_loop_is_coherent(nvim, hf_client):
    """End-to-end: build a syllabus, run a test answered by the user-LLM, and
    have the judge-LLM verify the whole interaction."""
    # 1. Create a project.
    created = _lua(
        nvim,
        "vim.json.encode(require('knowledge-builder.api').create_project("
        "{ name = 'LLM Loop Test', source_inputs = 'Python backend engineer role' }))",
    )
    assert created["ok"], created

    # 2. Build the syllabus from inputs (real LLM call inside Neovim).
    built = _lua(
        nvim,
        "vim.json.encode(require('knowledge-builder.api').build_syllabus("
        "'Python backend engineer: APIs, databases, testing', 120000))",
    )
    assert built["ok"], built
    assert len(built["topics"]) >= 1

    # 3. Start a test run (generates questions via LLM).
    run = _lua(nvim, "vim.json.encode(require('knowledge-builder.api').start_run('test', 180000))")
    assert run["ok"], run
    assert run["total"] >= 1

    # 4. Answer every question using the simulated-user LLM.
    transcript = {"syllabus": built["topics"], "exchanges": []}
    while True:
        cur = _lua(nvim, "vim.json.encode(require('knowledge-builder.api').get_current_question())")
        assert cur["ok"], cur
        if cur.get("done"):
            break
        question = cur["question"]
        answer = _ask_user_llm(hf_client, question)
        graded = _lua(
            nvim,
            "vim.json.encode(require('knowledge-builder.api').submit_answer("
            + json.dumps(answer)
            + ", 120000))",
        )
        assert graded["ok"], graded
        transcript["exchanges"].append(
            {
                "kind": question["kind"],
                "prompt": question["prompt"],
                "answer": answer,
                "score": graded.get("score"),
                "feedback": graded.get("feedback"),
            }
        )
        if graded.get("run_finished"):
            break

    # 5. Finalize and confirm levels were persisted.
    final = _lua(nvim, "vim.json.encode(require('knowledge-builder.api').finalize_run())")
    assert final["ok"], final
    assert final["levels"], "no per-topic levels computed"

    # 6. Judge the whole interaction.
    verdict = _judge(hf_client, transcript)
    assert verdict["verdict"] == "pass", f"judge rejected interaction: {verdict.get('reasons')}"
