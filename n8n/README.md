# n8n flows for the playback mesh

Version-controlled n8n workflows that consume the webhook sinks PCS and
OwnTube emit (`PCS_WEBHOOK_URLS` / `OWNTUBE_WEBHOOK_URLS` — see
`hooks/README.md` here and in the owntube repo). Neither server knows about
n8n: it is a URL that receives event JSON, exactly like any other receiver.

| File | Trigger | What it does |
|---|---|---|
| `mesh-pcs-playback.json` | `POST /webhook/pcs-playback` | Pocket Casts playback → OwnTube: filters to our media origin, resolves the channel, writes watch state, and on `archived` also removes the video from the collection its feed was published from |
| `mesh-owntube-playback.json` | `POST /webhook/owntube-playback` | OwnTube playback → PCS `/api/v1/playback`, which guards and writes it through to Pocket Casts |
| `mesh-replay-cron.json` | every 6 hours | Calls `POST /api/v1/hooks/replay` — the PC→OwnTube direction's outage recovery, mirroring what the feeds pusher already does for the other direction |

These reproduce what `hooks/owntube.sh` (here) and `hooks/pcs.sh` (owntube)
do. Run them **alongside** the scripts first: every action in the mesh is
idempotent, so double delivery is harmless, and the scripts keep the bridge
working while the flows earn trust. Delete the scripts once the execution
history is clean.

## Credentials (create once, in n8n)

Flows reference credentials by name; the secrets never enter this repo.

| Credential (type: Header Auth) | Header | Value |
|---|---|---|
| `Mesh webhook token` | `X-Webhook-Token` | matches `PCS_WEBHOOK_TOKEN` / `OWNTUBE_WEBHOOK_TOKEN` |
| `PCS operator token` | `Authorization` | `Bearer <PCS_AUTH_TOKEN>` |
| `OwnTube device token` | `Authorization` | `Bearer <OWNTUBE_TOKEN>` (expires every 30 days — see hooks/README.md) |

## Import

UI: *Workflows → Import from File*, then pick the credentials on each node
and activate. CLI equivalent, on the host running n8n:

```sh
docker cp mesh-pcs-playback.json n8n:/tmp/
docker exec n8n n8n import:workflow --input=/tmp/mesh-pcs-playback.json
```

Imported workflows arrive **inactive** — and re-importing an existing
workflow resets that flag, silently un-registering its webhook (a 404 on
the next delivery). After every import: activate and restart.

```sh
docker exec n8n n8n update:workflow --id=meshPcsPlayback01 --active=true
docker compose restart n8n
```

HTTP nodes carry a 30s timeout and one retry: a cold enclosure lookup makes
PCS rebuild its catalog index inside the request, which can outlast a
default timeout. The state such a call would have carried is re-offered by
the next replay sweep anyway.

Flows call services by their **public names**. That works from a
tier-routed container only because of `docker-tier-hairpin.service` on
vps: Docker network isolation drops DNAT-ed (published-port) packets as
they cross from a tier bridge to another docker bridge, so without it a
tier container cannot reach its own host's public hostname. The unit
accepts exactly those flows (`ctstate DNAT`) and nothing else.

## Why the flows are shaped this way

Branching is done with small Code nodes that return `[]` to stop a path,
rather than Switch/IF nodes: the logic reads as three lines of JavaScript,
the JSON stays portable across n8n versions (Code and HTTP Request node
schemas are the stable ones), and the filtering rules — "is this our media
origin", "is this an archive" — live where they can be commented.

Reaching `*.home.example.com` requires n8n to be on a tunnel tier
(`home-n8n`, segment 103). Tier = *who is calling*; what it may reach is an
OPNsense pass rule keyed on that source prefix, so granting n8n another home
service is one firewall rule, not another network.
