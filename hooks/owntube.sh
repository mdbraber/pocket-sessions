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

# A device token is an opaque encrypted JWT. Catching an obviously wrong value
# here beats every call failing with "Authentication required".
case "$OWNTUBE_TOKEN" in
  '{'*|'<'*)
    echo "owntube: OWNTUBE_TOKEN is not a token — looks like a response body" >&2
    exit 1
    ;;
esac

# tRPC distinguishes queries from mutations by HTTP method: a query takes
# GET ?input=<json>, a mutation takes POST with the body. Both are wrapped in
# {"json": …} because the router uses the superjson transformer.
#
# -L matters: an http:// URL redirects (308) to https and curl would otherwise
# hand back an empty body. No address family is forced — the tunnel carries
# both, and the home resolver answers AAAA first.
#
# Errors need checking three ways: curl exits 0 on an HTTP error, tRPC also
# reports some failures inside a 200 envelope, and a missing video has to stay
# distinguishable from a broken setup. Returns 2 for "OwnTube doesn't have it",
# 1 for anything else, and prints the response body on success.
trpc() { # trpc <get|post> <procedure> <json-input>
  _method=$1
  _proc=$2
  _input=$3

  if [ "$_method" = get ]; then
    _raw=$(curl -sS -L --max-time 25 -G -w '\n%{http_code}' \
      -H "Authorization: Bearer $OWNTUBE_TOKEN" \
      --data-urlencode "input={\"json\":$_input}" \
      "$OWNTUBE_URL/api/trpc/$_proc") || return 1
  else
    _raw=$(curl -sS -L --max-time 25 -X POST -w '\n%{http_code}' \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OWNTUBE_TOKEN" \
      -d "{\"json\":$_input}" \
      "$OWNTUBE_URL/api/trpc/$_proc") || return 1
  fi

  _code=$(printf '%s' "$_raw" | tail -n1)
  _body=$(printf '%s' "$_raw" | sed '$d')

  case "$_body" in
    *'"error"'*)
      case "$_body" in *NOT_FOUND*) return 2 ;; esac
      _msg=$(printf '%s' "$_body" | sed -nE 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
      echo "owntube: $_proc failed (HTTP $_code): ${_msg:-unknown error}" >&2
      return 1
      ;;
  esac

  case "$_code" in
    404) return 2 ;;
    2??) ;;
    *)
      echo "owntube: $_proc failed (HTTP $_code)" >&2
      return 1
      ;;
  esac

  printf '%s' "$_body"
}

# upsertEvent needs the channel id; video.detail resolves it (and is cached
# upstream, so this stays cheap).
rc=0
detail=$(trpc get "video.detail" "{\"videoId\":\"$video_id\"}") || rc=$?
if [ "$rc" = 2 ]; then
  echo "owntube: $video_id is not in OwnTube — ignoring" >&2
  exit 0
fi
[ "$rc" = 0 ] || exit 1

channel_id=$(printf '%s' "$detail" | sed -nE 's/.*"channelId"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
if [ -z "$channel_id" ]; then
  echo "owntube: no channelId in video.detail for $video_id" >&2
  exit 1
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

if trpc post "history.upsertEvent" "$input" >/dev/null; then
  echo "owntube: $PCS_EVENT $video_id at ${PCS_PLAYED_UP_TO:-0}s (completed=$completed)"
else
  echo "owntube: upsertEvent failed for $video_id" >&2
  exit 1
fi
