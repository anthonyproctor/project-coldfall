# On-disk formats

Project Coldfall's state is files. Nothing is hidden in a database, nothing needs an API
key, and no part of it is macOS-specific.

That is deliberate. It is what makes a front end in another language a UI
project rather than a rewrite: reimplement these six files and you have the
core. `ColdfallCore` imports nothing but Foundation, and `coldfall-cli` exposes
it as JSON for anything that would rather shell out than reimplement.

```sh
coldfall-cli desks              # configured desks and how each launches
coldfall-cli limits             # remaining quota per vendor
coldfall-cli usage --days 7     # consumption by vendor and by desk
coldfall-cli formats            # every path below, resolved
```

## `~/.config/coldfall/desks.toml`

The desks. `[desk.<name>]` tables; `group` is presentation only; `command`
overrides `runtime` and is run verbatim.

## `~/.config/coldfall/bridge.toml`

```toml
dir   = "~/.local/share/coldfall/mail"   # where threads live
scope = "~/src/api"                      # what the RESPONDER may read
runner = "./ask-claude.sh"               # optional: use your own handoff script
```

`scope` is a privacy boundary, not a convenience. See the README.

## `~/.local/share/coldfall/limits/<vendor>.json`

Remaining quota. **This is the extension point.** Any tool can publish a vendor
Project Coldfall has never heard of by writing this file; no code change is needed.

```json
{ "vendor": "claude", "weekPct": 3, "weekResetsAt": 1790442000,
  "fiveHourPct": 2, "fiveHourResetsAt": 1789886005,
  "planType": "max", "at": 1789879027.3 }
```

`at` is unix seconds when the reading was taken. Readings are used for 24 hours
and labelled with their age after 20 minutes — an idle vendor is precisely the
one with headroom, so hiding stale readings hides the useful answer. A window
whose `resets_at` has passed is dropped, because that one really is wrong.

Codex needs none of this: it writes quota into its own session rollout and
Project Coldfall reads it there.

## `~/.local/share/coldfall/sessions/<desk>.json`

Per-desk session state. Context belongs to a session, not a vendor.

```json
{ "desk": "hub", "ctxPct": 63, "model": "Claude Opus 5",
  "effort": "xhigh", "usd": 540.10, "at": 1789879027.3 }
```

Stale after 15 minutes, unlike quota. Context only moves while the desk is
working, so an old reading describes a conversation that has since grown.

## `~/.local/share/coldfall/mail/thread-<a>-<b>.md`

The cross-vendor thread. Append-only markdown, `## <who> · <timestamp>` per
turn. The whole file is sent as context on every ask, which is why it must
never be rewritten in place.

## `~/.config/coldfall/ui.json`

Window state: collapsed groups, tree position. Safe to delete.

## Consumption, read from the vendors

Not written by Project Coldfall; read from what the CLIs already keep.

| vendor | path | record |
|---|---|---|
| Claude | `~/.claude/projects/<proj>/<session>.jsonl` | `message.usage`; **deduplicate on `message.id`** |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `type: token_usage_record`, and `payload.rate_limits` for quota |

The dedupe is not optional. A streamed reply is written to the Claude
transcript more than once; counting every record roughly doubles the total.

## `~/.config/coldfall/schedules.json`

Prompts sent to desks at set times. A JSON array; **Desks ▸ Schedules…** opens it
with one example.

```json
[
  { "name": "Morning plan", "desk": "hub", "at": "09:00",
    "days": ["mon", "tue", "wed", "thu", "fri"],
    "prompt": "Plan today from the notes in this folder.",
    "precheck": "git log --since=yesterday --oneline | grep -q .",
    "skipOverWeekPct": 80, "enabled": true }
]
```

`at` is 24-hour local time. `days` is optional (every day without it). `precheck`
is a shell command run in the desk's folder; anything but exit 0 skips the run.
`skipOverWeekPct` skips it when the desk's vendor is at or past that much of its
weekly quota. Each run is appended to `~/.local/share/coldfall/schedule-runs.jsonl`
as `{"name","at","outcome","note"}`, where `outcome` is `sent`, `skipped_precheck`,
`skipped_quota`, `skipped_busy`, `missed` or `failed`.
