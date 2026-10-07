# Omarchy Laya Attention

<p align="center">
  <img src="public/laya-attention-hero.png" alt="Laya Attention — agent decisions in the bar, only the notifications that matter" width="100%">
</p>

A bar widget + service that decides **which notifications deserve you**, using
a locally running [Laya](https://huggingface.co/convaiinnovations/laya)
decision server. Two jobs:

1. **Agent attention** — watches AI agent panes via [herdr](https://herdr.dev)
   and notifies you only when an agent finishes, fails, or is waiting for
   you. Spinner lines and tool chatter stay silent.
2. **Notification triage** — watches your desktop notification popups and
   closes routine `progress`/`info` noise before it finishes drawing.
   Personal messages, errors, reminders, and OTP codes always pass through.

The problem with both: the default is all-or-nothing. Notify on everything
and you stop reading notifications; notify on nothing and you miss a failed
deploy. Laya — a non-autoregressive System-1 model — classifies each input in
a single forward pass (~200 ms on CPU), with calibrated probabilities, and
the plugin acts only above a confidence threshold you control from the panel.

## Requirements

- Omarchy
- [herdr](https://herdr.dev) managing your agent panes (`herdr agent list`
  must work)
- A **Laya decision server** on `localhost:8000`:

  ```bash
  uv venv ~/.local/share/laya
  uv pip install --python ~/.local/share/laya/.venv/bin/python "laya[serve]"
  ~/.local/share/laya/.venv/bin/laya-serve   # or run as a systemd user service
  ```

  First run downloads ~850 MB (English checkpoint) or ~1.5 GB with the
  multilingual router default.

## Install

```bash
omarchy plugin add https://github.com/cheapseatsecon/omarchy-laya-attention.git --enable
omarchy bar put cheapseatsecon.laya-attention right
```

Or by hand: clone this repo to
`~/.config/omarchy/plugins/cheapseatsecon.laya-attention/`, then:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable cheapseatsecon.laya-attention
omarchy bar put cheapseatsecon.laya-attention right
```

## The bar widget

A small dot in the bar:

| State | Meaning |
|---|---|
| **Accent** | at least one agent flagged as needing attention |
| **Dim** | all agents quiet, decision server reachable |
| **Hollow** | the decision server on `localhost:8000` is unreachable |

Click the dot to open the panel (below).

## The panel

Click the bar dot to open it. Everything the plugin knows is on one screen:

- **Agents** — every agent herdr tracks, with its last decision
  (`kind · probability · action`)
- **Controls**:
  - *Suppress notifications at* — the triage confidence threshold (50–95%)
  - *Triage enabled* — master switch for suppression; the agent watcher
    keeps running
  - *Agent attention at* — the agent-attention threshold (30–95%)
  - *Poll now* — run an agent-watch cycle immediately
  - *Refresh* — re-read the state files

Slider changes apply immediately (the triage watcher restarts with the new
threshold; agent polls pick it up on the next cycle) and persist to
`shell.json` under the plugin entry.

## How it works

**Agent attention** — every `intervalMs` (default 10 s):

1. `herdr agent list` → detect agents that transitioned **working → idle**
   (by `state_change_seq`)
2. `herdr agent read <pane>` → take the last 4,000 characters
3. `POST /v1/systemone` on the local laya server → classify
   `done / failed / waiting / progress / noise`
4. If the kind is `done`, `failed`, or `waiting` at ≥ the attention
   threshold → `herdr notification show "Agent needs attention"`

**Notification triage** — a resident watcher on the Omarchy shell's live
notification popups:

1. A new popup json appears in `~/.local/state/omarchy/notifications/`
2. `POST /v1/systemone` → classify
   `personal / error / reminder / otp / progress / info`
3. `progress` and `info` notifications are closed through the standard
   D-Bus interface (`CloseNotification`) — the same call a sender uses to
   retract its own notification, so nothing is muted at the bus level and
   senders get their normal closed callback

Agent decisions and notification-suppression actions are appended to private
JSONL logs under `~/.local/state/laya-attention/` (directory mode `0700`,
files mode `0600`). Notifications that are kept — including personal messages
and OTPs — are never persisted by this plugin:

```json
{"app": "docker", "summary": "Pulling layers 43%", "kind": "progress", "kind_prob": 0.83, "action": "suppressed"}
```

## Configuration

Settings live inline on the plugin's entry in `~/.config/omarchy/shell.json`
(hot-reloads on save). The panel sliders write these for you; edit by hand
if you prefer:

```json
{
  "id": "cheapseatsecon.laya-attention",
  "intervalMs": 10000,
  "threshold": 0.45,
  "triageEnabled": true,
  "triageThreshold": 0.6
}
```

| Key | Default | Meaning |
|---|---|---|
| `intervalMs` | `10000` | Agent-watch poll interval |
| `threshold` | `0.45` | Minimum kind probability to fire an agent notification |
| `triageEnabled` | `true` | Master switch for notification suppression |
| `triageThreshold` | `0.6` | Minimum kind probability to close a notification |

Thresholds are calibrated against the shipped checkpoints' observed
separation — agent attention: progress/noise ≤ 0.42 vs done ≥ 0.51 and
failed ≥ 0.93; triage: progress/info 0.52–0.86 vs everything else ≥ 0.9 on
the probe set. If your traffic differs, drag the sliders until the
suppression rate feels right, then read `triage.jsonl` to check what it
decided on your behalf.

## CLI

```bash
~/.config/omarchy/plugins/cheapseatsecon.laya-attention/bin/omarchy-laya-attention poll      # one agent-watch cycle now
~/.config/omarchy/plugins/cheapseatsecon.laya-attention/bin/omarchy-laya-attention status    # tracked agents + recent decisions
~/.config/omarchy/plugins/cheapseatsecon.laya-attention/bin/omarchy-laya-attention test "…"  # classify arbitrary text through laya
```

## Privacy

Everything runs on this machine: herdr, laya, and the classification all
stay local. Agent output and notification text never leave the box. The
only network traffic is to `localhost:8000`.

## Remove

```bash
omarchy plugin remove cheapseatsecon.laya-attention
```

That deletes the plugin directory and its `shell.json` entry. The state
directory (`~/.local/state/laya-attention/`) and the laya venv are left
in place; remove them by hand if you want a full cleanup.

## Troubleshooting

```bash
# Is the plugin service alive and what does it know?
~/.config/omarchy/plugins/cheapseatsecon.laya-attention/bin/omarchy-laya-attention status

# Is the decision server reachable?
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8000/v1/systemone \
  -H 'Content-Type: application/json' \
  -d '{"state":"ping","questions":{"k":{"type":"noul","instructions":"live check"}}}'

# Are agents visible to the plugin?
herdr agent list
```

If the plugin fails to load, check the shell log:

```bash
tail -n 100 $(ls -t /run/user/$UID/quickshell/by-id/*/log.qslog | head -1)
```

- **Hollow dot** — the decision server is down; start `laya-serve`.
- **No agent notifications** — check the threshold: a `done` at 0.40 with
  `threshold: 0.45` stays silent by design. Lower *Agent attention at* and
  watch the next decision in `decisions.jsonl`.
- **Too many suppressed notifications** — raise *Suppress notifications at*,
  or flip *Triage enabled* off; every suppressed one is in `triage.jsonl`
  with the reason.

## License

MIT
