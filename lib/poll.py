#!/usr/bin/env python3
"""One poll cycle for the Laya Attention plugin.

Detects AI agents (via herdr) that just transitioned working -> idle, reads
their terminal tail, asks the local Laya decision server what the output
means, and fires a herdr notification when the output deserves attention.

State (last-seen agent statuses and the decision log) lives under
~/.local/state/laya-attention/.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "laya-attention")
AGENTS_STATE = os.path.join(STATE_DIR, "agents.json")
DECISIONS_LOG = os.path.join(STATE_DIR, "decisions.jsonl")
LAYA_URL = os.environ.get("LAYA_URL", "http://127.0.0.1:8000/v1/systemone")

NOTIFY_THRESHOLD = float(os.environ.get("LAYA_NOTIFY_THRESHOLD", "0.45"))  # minimum top-probability of `kind` to notify
TAIL_CHARS = 4000

QUESTIONS = {
    "kind": {
        "type": "choice",
        "instructions": "What does this AI agent terminal output represent?",
        "criteria": {
            "waiting": "the agent is asking the human a question or waiting for input",
            "failed": "the agent hit an error, crash, or failed the task",
            "done": "the agent completed the requested work",
            "progress": "routine progress, tool output, or the agent still working",
            "noise": "spinner, status line, banner, or empty content",
        },
    }
}

# kinds that warrant a notification, in priority order
NOTIFY_KINDS = {"waiting", "failed", "done"}


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def laya_classify(text: str) -> tuple[str, float, float]:
    """Return (kind, top_prob, needs_attention) for a chunk of terminal output."""
    body = json.dumps({"state": text[-TAIL_CHARS:], "questions": QUESTIONS}).encode()
    req = urllib.request.Request(LAYA_URL, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            d = json.load(resp)
    except Exception as e:  # server down, timeout, bad payload
        raise RuntimeError(f"laya request failed: {e}") from e
    a = d["answers"]["kind"]
    kind = a["choice"]
    top = float(a["probabilities"][kind])
    # noul head exists only when asked; skip it here — kind is the decision signal
    return kind, top, top


def load_state() -> dict:
    try:
        with open(AGENTS_STATE) as f:
            return json.load(f)
    except Exception:
        return {}


def ensure_private_state_dir() -> None:
    """Keep plugin state inaccessible to other local users.

    Explicitly correct an existing directory too: os.makedirs() applies its
    mode only when it creates the directory, and users commonly have umask
    022.
    """
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)


def save_state(state: dict) -> None:
    ensure_private_state_dir()
    fd, tmp = tempfile.mkstemp(prefix=".agents.", dir=STATE_DIR, text=True)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, AGENTS_STATE)
    os.chmod(AGENTS_STATE, 0o600)


def append_decision(entry: dict) -> None:
    ensure_private_state_dir()
    with open(DECISIONS_LOG, "a") as f:
        # The directory is already private; make the file private as well so
        # it stays protected if it is later moved or the directory mode drifts.
        os.chmod(DECISIONS_LOG, 0o600)
        f.write(json.dumps(entry) + "\n")


def herdr_agents() -> list[dict]:
    try:
        out = subprocess.run(
            ["herdr", "agent", "list"], capture_output=True, text=True, timeout=10
        ).stdout
        return json.loads(out).get("result", {}).get("agents", [])
    except Exception as e:
        log(f"herdr agent list failed: {e}")
        return []


def pane_tail(pane_id: str) -> str:
    try:
        out = subprocess.run(
            ["herdr", "agent", "read", pane_id, "--source", "recent"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        return out[-TAIL_CHARS:]
    except Exception as e:
        log(f"herdr agent read {pane_id} failed: {e}")
        return ""


def notify(title: str, body: str) -> None:
    subprocess.run(
        ["herdr", "notification", "show", title, "--body", body],
        capture_output=True, timeout=10,
    )


def main() -> int:
    threshold = NOTIFY_THRESHOLD
    args = sys.argv[1:]
    if "--threshold" in args:
        i = args.index("--threshold")
        try:
            threshold = float(args[i + 1])
        except (IndexError, ValueError):
            pass
    ensure_private_state_dir()
    prev = load_state()
    agents = herdr_agents()

    now_state: dict = {}
    transitions: list[tuple[str, dict]] = []

    for a in agents:
        pid = a.get("pane_id") or a.get("terminal_id")
        if not pid:
            continue
        status = a.get("agent_status") or "unknown"
        seq = a.get("state_change_seq", 0)
        title = a.get("terminal_title_stripped") or pid
        p = prev.get(pid, {})
        # working -> idle at a newer seq = the agent just finished a turn
        transition = (
            bool(p)
            and p.get("status") == "working"
            and status == "idle"
            and seq > p.get("seq", 0)
        )
        now_state[pid] = {"status": status, "seq": seq, "title": title}
        if transition:
            transitions.append((pid, now_state[pid]))

    save_state(now_state)

    notified = 0
    for pid, info in transitions:
        tail = pane_tail(pid)
        if not tail.strip():
            continue
        try:
            kind, top, _ = laya_classify(tail)
        except RuntimeError as e:
            log(f"{pid}: {e}")
            continue
        should = kind in NOTIFY_KINDS and top >= threshold
        entry = {
            "ts": time.time(),
            "pane": pid,
            "agent": info["title"],
            "kind": kind,
            "prob": round(top, 4),
            "action": "notified" if should else "silent",
        }
        append_decision(entry)
        if should:
            notify("Agent needs attention", f"{info['title']} — {kind} ({top:.2f})")
            notified += 1

    print(json.dumps({
        "transitions": len(transitions),
        "notified": notified,
        "agents": {pid: {"status": s["status"], "title": s["title"]} for pid, s in now_state.items()},
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
