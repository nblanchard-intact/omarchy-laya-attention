#!/usr/bin/env python3
"""Resident desktop-notification triage watcher.

Watches the omarchy shell's live notification popup directory with inotify.
Each new popup json (a notification currently on screen) is classified by the
local Laya decision server on two axes:

  important (noul)  — does the user need to see this now?
  kind (choice)     — personal / actionable / otp / noise

A notification is closed through the standard D-Bus interface when it is
neither important nor personal/actionable/otp — routine progress and job
status never interrupt, everything else passes through untouched.

Decisions append to ~/.local/state/laya-attention/triage.jsonl.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.request

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "laya-attention")
TRIAGE_LOG = os.path.join(STATE_DIR, "triage.jsonl")
POPUP_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "omarchy/notifications")
LAYA_URL = os.environ.get("LAYA_URL", "http://127.0.0.1:8000/v1/systemone")

THRESHOLD = 0.6  # minimum confidence to act on either axis

QUESTIONS = {
    "kind": {
        "type": "choice",
        "instructions": "What kind of notification is this?",
        "criteria": {
            "personal": "a message from a person, on a chat or social app",
            "error": "an error or failure that needs attention",
            "reminder": "a reminder about a scheduled event or deadline",
            "otp": "a one-time code or security token",
            "progress": "routine automated progress or job status",
            "info": "general information that can wait",
        },
    },
}

# kinds that always pass through regardless of probability; everything else
# (progress, info) is suppressed when its own probability is high enough.
PASS_KINDS = {"personal", "error", "reminder", "otp"}


PIDFILE = os.path.join(STATE_DIR, "triage.pid")


def write_pidfile() -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))


def kill_stale() -> None:
    """Terminate a previous watcher so only one runs (settings restarts)."""
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
        if pid != os.getpid():
            os.kill(pid, 15)
            time.sleep(0.2)
    except Exception:
        pass


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def classify(app: str, summary: str, body: str) -> tuple[str, float]:
    text = f"App: {app}\nTitle: {summary}\nBody: {body}".strip()[:4000]
    payload = json.dumps({"state": text, "questions": QUESTIONS}).encode()
    req = urllib.request.Request(LAYA_URL, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=8) as resp:
        d = json.load(resp)
    kind_a = d["answers"]["kind"]
    kind = kind_a["choice"]
    kind_prob = float(kind_a["probabilities"][kind])
    return kind, kind_prob


def append_decision(entry: dict) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(TRIAGE_LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


def close_notification(dbus_id: int) -> None:
    # The omarchy shell owns org.freedesktop.Notifications; this is the same
    # call a sender uses to retract its own notification.
    subprocess.run(
        ["gdbus", "call", "--session",
         "--dest", "org.freedesktop.Notifications",
         "--object-path", "/org/freedesktop/Notifications",
         "--method", "org.freedesktop.Notifications.CloseNotification",
         str(dbus_id)],
        capture_output=True, timeout=8,
    )


def triage_file(path: str, threshold: float) -> None:
    n = None
    for _ in range(3):
        try:
            with open(path) as f:
                n = json.load(f)
            break
        except json.JSONDecodeError:
            time.sleep(0.1)  # writer may still be mid-write
        except FileNotFoundError:
            return  # popup already gone (expired)
    if n is None:
        return

    dbus_id = n.get("originalId", n.get("id"))
    app = n.get("app", "")
    summary = n.get("summary", "")
    body = n.get("body", "")
    try:
        kind, kind_prob = classify(app, summary, body)
    except Exception as e:
        log(f"triage classify failed: {e}")
        return

    # Pass-through kinds (personal/error/reminder/otp) are never suppressed.
    # progress/info are suppressed when the classifier is confident.
    suppress = kind not in PASS_KINDS and kind_prob >= threshold

    append_decision({
        "ts": time.time(), "file": os.path.basename(path), "dbus_id": dbus_id,
        "app": app, "summary": summary,
        "kind": kind, "kind_prob": round(kind_prob, 4),
        "action": "suppressed" if suppress else "kept",
    })
    if suppress and isinstance(dbus_id, int) and dbus_id > 0:
        close_notification(dbus_id)
        log(f"suppressed: {app} — {summary} ({kind} {kind_prob:.2f})")


def main() -> int:
    threshold = THRESHOLD
    args = sys.argv[1:]
    if "--threshold" in args:
        i = args.index("--threshold")
        try:
            threshold = float(args[i + 1])
        except (IndexError, ValueError):
            pass

    kill_stale()
    write_pidfile()
    os.makedirs(POPUP_DIR, exist_ok=True)
    log(f"watching {POPUP_DIR} (threshold {threshold})")

    proc = subprocess.Popen(
        ["inotifywait", "-m", "-q", "-e", "close_write,moved_to",
         "--format", "%w%f", POPUP_DIR],
        stdout=subprocess.PIPE, text=True,
    )
    try:
        for line in proc.stdout:
            path = line.strip()
            if not path.endswith(".json"):
                continue
            if "history" in path or "images" in path or "laya-attention" in path:
                continue
            if threshold <= 0:
                continue  # triage disabled; keep the watcher alive
            triage_file(path, threshold)
    except KeyboardInterrupt:
        proc.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
