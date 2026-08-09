#!/usr/bin/env python3
"""Verify every AI CLI still accepts the arguments the app passes it.

Two levels:

  ./scripts/check-agents.py           contract check — free, no model calls
  ./scripts/check-agents.py --live    also send one tiny prompt per provider

The contract check exists because a CLI can accept a flag on one subcommand
and reject it on another. Codex is the live example: `codex exec` takes
`--sandbox`, but `codex exec resume` does not, so the app worked on a pet's
first message and hard-failed on every follow-up. Checking `codex exec --help`
alone does not catch that — each invocation path has to be checked separately.

Exit code is non-zero if any check fails, so this can gate a release.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "app" / "MiniPetAgents"

# Every distinct argv shape the app builds, per provider. `help` is the
# subcommand path whose --help must list the flags in `flags`.
PROVIDERS = {
    "claude": {
        "binary": "claude",
        "source": "ClaudeSession.swift",
        "variants": [
            {"name": "turn", "help": [], "flags": [
                "-p", "--output-format", "--input-format", "--verbose",
                "--dangerously-skip-permissions", "--model"]},
        ],
        "live": {
            "args": ["-p", "--output-format", "stream-json", "--input-format",
                     "stream-json", "--verbose", "--dangerously-skip-permissions"],
            "stdin": json.dumps({"type": "user", "message": {"role": "user",
                     "content": [{"type": "text", "text": "reply with exactly: OK"}]}}) + "\n",
        },
    },
    "codex": {
        "binary": "codex",
        "source": "CodexSession.swift",
        "variants": [
            {"name": "first turn", "help": ["exec"], "flags": [
                "--json", "--skip-git-repo-check", "-c", "--model"]},
            {"name": "resume", "help": ["exec", "resume"], "flags": [
                "--json", "--skip-git-repo-check", "-c", "--model"]},
        ],
        "live": {"args": ["exec", "--json", "--skip-git-repo-check",
                          "-c", 'sandbox_mode="workspace-write"',
                          "reply with exactly: OK"], "stdin": ""},
    },
    "copilot": {
        "binary": "copilot",
        "source": "CopilotSession.swift",
        "variants": [
            {"name": "turn", "help": [], "flags": [
                "-p", "--continue", "--output-format", "-s", "--allow-all", "--model"]},
        ],
        "live": {"args": ["-p", "reply with exactly: OK",
                          "--output-format", "json", "--allow-all"], "stdin": ""},
    },
    "cursor": {
        "binary": "cursor-agent",
        "source": "CursorSession.swift",
        "variants": [
            {"name": "turn", "help": [], "flags": [
                "-p", "--output-format", "--force", "--resume", "--model"]},
            {"name": "model list", "help": [], "flags": ["--list-models"]},
        ],
        "live": {"args": ["-p", "--output-format", "stream-json", "--force",
                          "reply with exactly: OK"], "stdin": ""},
    },
    # Implemented but hidden in the UI (see AgentProvider.selectableCases).
    "gemini": {
        "binary": "agy",
        "source": "GeminiSession.swift",
        "variants": [
            {"name": "turn", "help": [], "flags": ["-p", "--conversation", "--model"]},
        ],
        "live": None,
        "optional": True,
    },
}

FLAG_RE = re.compile(r'"(--?[a-zA-Z][a-zA-Z0-9-]*)"')


def run(cmd, stdin="", timeout=90):
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "<timed out>"
    except FileNotFoundError:
        return 127, "<not found>"


def declared_flags(source_file):
    """Flags actually present in the session's Swift source."""
    text = (SRC / source_file).read_text()
    # Only the argv-building region: from the first `var args` to `proc.arguments`.
    m = re.search(r"var args[\s\S]*?proc\.arguments = args", text)
    region = m.group(0) if m else text
    return {f for f in FLAG_RE.findall(region)}


def check_contract(name, spec):
    """Every flag the app passes must appear in --help for that subcommand path."""
    results = []
    binary = shutil.which(spec["binary"])
    if not binary:
        return [(name, "binary", "SKIP", f"{spec['binary']} not installed")]

    # Drift guard: a flag added in Swift but not listed here means this test
    # has gone stale and is no longer covering the real invocation.
    listed = {f for v in spec["variants"] for f in v["flags"]}
    actual = declared_flags(spec["source"])
    undeclared = actual - listed
    if undeclared:
        results.append((name, "drift", "FAIL",
                        f"{spec['source']} passes {sorted(undeclared)} — not covered by this test"))

    for v in spec["variants"]:
        rc, help_text = run([binary] + v["help"] + ["--help"])
        if rc not in (0, 1) or not help_text.strip():
            results.append((name, v["name"], "FAIL",
                            f"`{' '.join([spec['binary']] + v['help'])} --help` failed (rc={rc})"))
            continue
        missing = [f for f in v["flags"] if not re.search(rf"(?<![\w-]){re.escape(f)}(?![\w-])", help_text)]
        if missing:
            results.append((name, v["name"], "FAIL",
                            f"CLI no longer accepts {missing} on `{' '.join([spec['binary']] + v['help']) or spec['binary']}`"))
        else:
            results.append((name, v["name"], "PASS",
                            f"{len(v['flags'])} flags accepted"))
    return results


def check_live(name, spec):
    binary = shutil.which(spec["binary"])
    if not binary:
        return (name, "live", "SKIP", "binary not installed")
    if not spec.get("live"):
        return (name, "live", "SKIP", "no live test defined")
    rc, out = run([binary] + spec["live"]["args"], stdin=spec["live"]["stdin"], timeout=180)
    if "Raw mode is not supported" in out:
        return (name, "live", "FAIL", "CLI tried to render an interactive TUI")
    if "unexpected argument" in out or "unknown option" in out.lower():
        return (name, "live", "FAIL", out.strip().splitlines()[0][:100])
    if "OK" in out:
        return (name, "live", "PASS", "round trip returned a reply")
    return (name, "live", "FAIL", f"rc={rc}, no reply found: {out.strip()[:100]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true",
                    help="also send one tiny prompt per provider (uses real tokens)")
    ap.add_argument("--only", help="check a single provider by name")
    args = ap.parse_args()

    names = [args.only] if args.only else list(PROVIDERS)
    rows, failed = [], False

    for name in names:
        spec = PROVIDERS[name]
        for r in check_contract(name, spec):
            rows.append(r)
        if args.live:
            rows.append(check_live(name, spec))

    width = max(len(f"{r[0]} / {r[1]}") for r in rows) + 2
    print()
    for provider, check, status, detail in rows:
        label = f"{provider} / {check}"
        mark = {"PASS": "ok  ", "FAIL": "FAIL", "SKIP": "skip"}[status]
        print(f"  {mark}  {label:<{width}} {detail}")
        if status == "FAIL" and not PROVIDERS[provider].get("optional"):
            failed = True
    print()

    if failed:
        print("Some providers would fail inside the app. Fix before shipping.")
        return 1
    print("All installed providers accept the arguments the app passes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
