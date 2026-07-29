#!/bin/sh
# PCS playback hook → OwnTube watch history.
#
# Fires for every playback event PCS sees. Episodes whose enclosure doesn't
# come from the configured OwnTube host are ignored, so this can sit alongside
# hooks for other services.
#
# Install: copy into the hooks directory (PCS_HOOKS_DIR, e.g. /data/hooks),
# `chmod +x`, and set in the host .env:
#   OWNTUBE_URL=http://owntube.home.example.com      # reachable over WireGuard
#   OWNTUBE_TOKEN=<device token from auth.deviceLogin / device pairing>
#
# PCS passes the event as PCS_* environment variables (and JSON on stdin, which
# this script doesn't need — no jq dependency).

set -eu

# Not configured yet is not a failure — stay silent so the server log doesn't
# fill with warnings before OWNTUBE_URL/OWNTUBE_TOKEN are set.
[ -n "${OWNTUBE_URL:-}" ] || exit 0
[ -n "${OWNTUBE_TOKEN:-}" ] || exit 0

[ -n "${PCS_EPISODE_URL:-}" ] || exit 0

# Only handle enclosures served by this OwnTube instance.
owntube_host=$(printf '%s' "$OWNTUBE_URL" | sed -E 's#^[a-z]+://##; s#/.*$##; s#:.*$##')
episode_host=$(printf '%s' "$PCS_EPISODE_URL" | sed -E 's#^[a-z]+://##; s#/.*$##; s#:.*$##')
[ "$episode_host" = "$owntube_host" ] || exit 0

# The YouTube id OwnTube keys history on. Accepts the shapes a feed is likely
# to use: ?v=<id>, /watch/<id>, or <id>.<ext> as the last path segment.
video_id=$(printf '%s' "$PCS_EPISODE_URL" | sed -nE 's#.*[?&]v=([A-Za-z0-9_-]{11}).*#\1#p')
[ -n "$video_id" ] || video_id=$(printf '%s' "$PCS_EPISODE_URL" | sed -nE 's#.*/(watch|video|v)/([A-Za-z0-9_-]{11}).*#\2#p')
[ -n "$video_id" ] || video_id=$(printf '%s' "$PCS_EPISODE_URL" | sed -nE 's#.*/([A-Za-z0-9_-]{11})(\.[A-Za-z0-9]+)?(\?.*)?$#\1#p')
if [ -z "$video_id" ]; then
  echo "no video id in $PCS_EPISODE_URL" >&2
  exit 0
fi

trpc() { # trpc <procedure> <json-input>
  curl -sS -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OWNTUBE_TOKEN" \
    --max-time 20 \
    -d "{\"json\":$2}" \
    "$OWNTUBE_URL/api/trpc/$1"
}

# upsertEvent needs the channel id; video.detail resolves it (and is cached
# upstream, so this stays cheap).
detail=$(trpc "video.detail" "{\"videoId\":\"$video_id\"}" || true)
channel_id=$(printf '%s' "$detail" | sed -nE 's/.*"channelId":"([^"]+)".*/\1/p' | head -1)
if [ -z "$channel_id" ]; then
  echo "could not resolve channelId for $video_id" >&2
  exit 0
fi

# PC's model maps straight onto OwnTube's: playedUpTo is the resume point,
# playingStatus 3 means finished. `completed` is sticky server-side, so a
# later progress event can't un-finish a video.
completed=false
[ "${PCS_PLAYING_STATUS:-0}" = "3" ] && completed=true

title_json=""
if [ -n "${PCS_EPISODE_TITLE:-}" ]; then
  escaped=$(printf '%s' "$PCS_EPISODE_TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  title_json=",\"videoTitle\":\"$escaped\""
fi

input=$(cat <<EOF
{"videoId":"$video_id","channelId":"$channel_id","durationWatched":${PCS_PLAYED_UP_TO:-0},"positionSeconds":${PCS_PLAYED_UP_TO:-0},"completed":$completed,"videoDurationSeconds":${PCS_DURATION:-0}$title_json}
EOF
)

if trpc "history.upsertEvent" "$input" >/dev/null; then
  echo "owntube: $PCS_EVENT $video_id at ${PCS_PLAYED_UP_TO:-0}s (completed=$completed)"
else
  echo "owntube: upsertEvent failed for $video_id" >&2
  exit 1
fi
