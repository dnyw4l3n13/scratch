#!/usr/bin/env bash
#
# NanoClaw container smoke test — independent check.
#
# Spawns the agent container the same way the host does (real dotfile
# mounts + stubbed session DBs), invokes /app/startup-check.sh, and
# reports the per-check ✓/✗ result.
#
# Use this to verify a freshly-built image without going through nanoclaw's
# full message-routing path. The startup-check itself is baked into the
# image — the source-of-truth for it lives in nanoclaw's repo at
# container/startup-check.sh; this script is the "running it standalone"
# wrapper.
#
# Usage:
#   ./container-smoke-test.sh                       # defaults
#   ./container-smoke-test.sh --image <tag>          # pin a specific image
#   ./container-smoke-test.sh --src <path>           # bind-mount a nanoclaw
#                                                    # agent-runner src tree
#                                                    # at /app/src (so the
#                                                    # mount-presence check
#                                                    # passes)
#   ./container-smoke-test.sh --skills <path>        # bind-mount a skills dir
#   ./container-smoke-test.sh --shared-md <path>     # bind-mount /app/CLAUDE.md
#   ./container-smoke-test.sh --with-onecli          # forward host's OneCLI
#                                                    # env (HTTPS_PROXY,
#                                                    # SSL_CERT_FILE) so the
#                                                    # 2 OneCLI checks pass
#   ./container-smoke-test.sh --keep-workspace       # keep the temp DB dir
#                                                    # so you can poke at
#                                                    # /workspace/outbound.db
#                                                    # afterwards
#   ./container-smoke-test.sh --runtime podman       # default: docker
#
# Auto-detection: if NANOCLAW_HOME is set or ~/nanoclaw exists, the
# script auto-mounts the relevant source paths from there so the
# mount-presence checks pass without you having to specify them.
#
# Exit:
#   0  — every check passed (50/50 with --with-onecli + a nanoclaw checkout)
#   42 — at least one check failed (mirrors startup-check.sh)
#   2  — usage error / missing image
#
set -euo pipefail

IMAGE=""
SRC=""
SKILLS=""
SHARED_MD=""
WITH_ONECLI=0
KEEP_WS=0
RUNTIME="${CONTAINER_RUNTIME:-docker}"

while [ $# -gt 0 ]; do
  case "$1" in
    --image)        IMAGE="$2"; shift 2 ;;
    --src)          SRC="$2"; shift 2 ;;
    --skills)       SKILLS="$2"; shift 2 ;;
    --shared-md)    SHARED_MD="$2"; shift 2 ;;
    --with-onecli)  WITH_ONECLI=1; shift ;;
    --keep-workspace) KEEP_WS=1; shift ;;
    --runtime)      RUNTIME="$2"; shift 2 ;;
    -h|--help)      sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed 's/^# \?//;/^set -euo/d'; exit 0 ;;
    *)              echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Auto-detect a nanoclaw checkout to source the bind-mounts from.
NC="${NANOCLAW_HOME:-$HOME/nanoclaw}"
if [ -d "$NC/container/agent-runner/src" ] && [ -z "$SRC" ];   then SRC="$NC/container/agent-runner/src";  fi
if [ -d "$NC/container/skills" ]            && [ -z "$SKILLS" ]; then SKILLS="$NC/container/skills";        fi
if [ -f "$NC/container/CLAUDE.md" ]         && [ -z "$SHARED_MD" ]; then SHARED_MD="$NC/container/CLAUDE.md"; fi

# Default image: most recent nanoclaw-agent-v2-* tag, falling back to plain
# nanoclaw-agent. Nanoclaw appends a per-install slug to the image name so
# multiple installs on the same host don't collide; we just take whatever
# is freshest.
if [ -z "$IMAGE" ]; then
  IMAGE=$("$RUNTIME" images --format '{{.Repository}}:{{.Tag}}' \
    | awk '/^nanoclaw-agent(-v2)?(-[0-9a-f]+)?:latest$/ {print; exit}')
fi
if [ -z "$IMAGE" ]; then
  echo "no nanoclaw image found locally; build first or pass --image <tag>" >&2
  exit 2
fi
echo "[smoke] runtime: $RUNTIME"
echo "[smoke] image:   $IMAGE"
echo "[smoke] src:     ${SRC:-<unset — /app/src/index.ts check will FAIL>}"
echo "[smoke] skills:  ${SKILLS:-<unset — /app/skills check will FAIL>}"
echo "[smoke] CLAUDE:  ${SHARED_MD:-<unset — /app/CLAUDE.md check will FAIL>}"
echo "[smoke] onecli:  $([ $WITH_ONECLI -eq 1 ] && echo 'forwarding host env' || echo 'not forwarded — 2 OneCLI checks will FAIL')"
echo

WORKSPACE=$(mktemp -d -t nanoclaw-smoke.XXXXXX)
trap 'if [ "$KEEP_WS" -eq 0 ]; then rm -rf "$WORKSPACE"; else echo "[smoke] kept workspace: $WORKSPACE"; fi' EXIT

# Stub the session DBs the way nanoclaw would. inbound has one row so the
# Discord-post path can find a destination (it stays a stub — the smoke
# test does not actually deliver anywhere).
sqlite3 "$WORKSPACE/inbound.db" "
  CREATE TABLE messages_in (seq INTEGER, platform_id TEXT, channel_type TEXT, thread_id TEXT, content TEXT);
  INSERT INTO messages_in VALUES (0, 'smoke-test', 'discord', NULL, '{\"text\":\"smoke\"}');
"
sqlite3 "$WORKSPACE/outbound.db" "
  CREATE TABLE messages_out (id TEXT PRIMARY KEY, seq INTEGER, timestamp TEXT, kind TEXT, platform_id TEXT, channel_type TEXT, thread_id TEXT, content TEXT);
"

ARGS=(
  --rm
  -v "$HOME/.gitconfig:/home/node/.gitconfig:ro"
  -v "$HOME/.gnupg:/home/node/.gnupg-host:ro"
  -v "$HOME/.ssh:/home/node/.ssh:ro"
  -v "$HOME/.config/gh:/home/node/.config/gh:ro"
  -v "$WORKSPACE:/workspace"
  --user "$(id -u):$(id -g)"
  -e HOME=/home/node
  -e "TZ=${TZ:-Europe/London}"
)

[ -n "$SRC" ]       && ARGS+=(-v "$SRC:/app/src:ro")
[ -n "$SKILLS" ]    && ARGS+=(-v "$SKILLS:/app/skills:ro")
[ -n "$SHARED_MD" ] && ARGS+=(-v "$SHARED_MD:/app/CLAUDE.md:ro")

if [ "$WITH_ONECLI" -eq 1 ]; then
  [ -n "${HTTPS_PROXY:-}" ]    && ARGS+=(-e "HTTPS_PROXY=$HTTPS_PROXY")
  [ -n "${SSL_CERT_FILE:-}" ]  && ARGS+=(-e "SSL_CERT_FILE=$SSL_CERT_FILE" -v "$SSL_CERT_FILE:$SSL_CERT_FILE:ro")
fi

# We replicate entrypoint.sh's gpg-copy + lockfile-strip preamble manually
# instead of running entrypoint.sh, because entrypoint.sh would `exec bun
# run /app/src/index.ts` after the check passes — that's the agent itself,
# which needs Anthropic creds + a real session. Smoke test only wants the
# pre-flight verdict.
ARGS+=(--entrypoint /bin/bash "$IMAGE" -c '
  set -e
  if [ -d /home/node/.gnupg-host ] && [ ! -d /home/node/.gnupg ]; then
    cp -a /home/node/.gnupg-host /home/node/.gnupg
    chmod 700 /home/node/.gnupg
    find /home/node/.gnupg -type f \( -name ".#lk*" -o -name "*.lock" \) -delete 2>/dev/null || true
  fi
  /app/startup-check.sh
')

set +e
"$RUNTIME" run "${ARGS[@]}"
EC=$?
set -e

echo
case "$EC" in
  0)  echo "[smoke] PASS — every check green";;
  42) echo "[smoke] FAIL — startup-check reported one or more failures";;
  *)  echo "[smoke] container exited with unexpected code $EC";;
esac

if [ "$KEEP_WS" -eq 1 ]; then
  echo "[smoke] outbound report (if posted):"
  sqlite3 "$WORKSPACE/outbound.db" "SELECT json_extract(content,'\$.text') FROM messages_out;" | sed 's/^/    /'
fi

exit "$EC"
