#!/bin/bash
#
# Run Claude Code in the ROCm + arduino-cli container.
#
#   ./run.sh                    start claude in the current directory
#   ./run.sh --continue         any args starting with "-" go to claude
#   ./run.sh bash               anything else runs as a command
#   ./run.sh --build [...]      (re)build the image first, pulling a fresh base
#
# Environment overrides:
#   WORKSPACE      host directory to work in        (default: $PWD)
#   IMAGE          image tag                         (default: claude-agent:latest)
#   NAME           container name                    (default: claude-agent-<workspace>)
#   CLAUDE_VOLUME  volume holding Claude's login     (default: claude-agent-claude)
#   AGENT_USER     user name inside the image        (default: agent)
#   DOCKER_ARGS    extra "docker run" arguments, word-split
#
set -euo pipefail

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

IMAGE=${IMAGE:-claude-agent:latest}
WORKSPACE=$(readlink -f "${WORKSPACE:-$PWD}")
CLAUDE_VOLUME=${CLAUDE_VOLUME:-claude-agent-claude}
AGENT_USER=${AGENT_USER:-agent}

# ~/rocm-hip.git -> /work/rocm-hip
ws_name=$(basename "$WORKSPACE")
ws_name=${ws_name%.git}
NAME=${NAME:-claude-agent-$(tr -c 'a-zA-Z0-9_.\n-' '-' <<<"$ws_name")}
container_home=/home/$AGENT_USER
container_ws=/work/$ws_name

# The image user can't be root; fall back to 1000 if run as root.
uid=$(id -u); gid=$(id -g)
[ "$uid" = 0 ] && uid=1000
[ "$gid" = 0 ] && gid=1000

build=()
if [ "${1:-}" = "--build" ]; then
    build=(--pull)
    shift
fi

if [ ${#build[@]} -gt 0 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build \
        "${build[@]}" \
        --build-arg UID="$uid" \
        --build-arg GID="$gid" \
        --build-arg USERNAME="$AGENT_USER" \
        -t "$IMAGE" \
        "$here"
fi

# shellcheck disable=SC2054  # commas in --tmpfs options are intentional
args=(
    --rm
    --init
    --name "$NAME"
    --hostname "$NAME"
    --security-opt seccomp=unconfined
    --ipc=host
    --ulimit memlock=-1:-1
    --ulimit stack=67108864:67108864
    --tmpfs /tmp:rw,suid,exec,size=1G
    --tmpfs /var/tmp:rw,suid,exec,size=1G
    -v "$WORKSPACE:$container_ws"
    -w "$container_ws"
    -v "$CLAUDE_VOLUME:$container_home/.claude"
    -e TERM="${TERM:-xterm-256color}"
)

if [ -t 0 ] && [ -t 1 ]; then
    args+=(-it)
else
    args+=(-i)
fi

# Pass devices through and add whatever groups own them on *this* host
# (replaces the hardcoded --group-add 109/986/992).
declare -A gids=()
add_dev() {
    local dev=$1
    [ -c "$dev" ] || return 0
    args+=(--device="$dev")
    local gid
    gid=$(stat -c %g "$dev")
    [ "$gid" != 0 ] && gids[$gid]=1
    return 0
}

add_dev /dev/kfd                                  # ROCm compute
for d in /dev/dri/card* /dev/dri/renderD*; do     # GPU
    add_dev "$d"
done
for d in /dev/ttyUSB* /dev/ttyACM*; do            # ESP32 / Arduino serial
    add_dev "$d"
done
for g in "${!gids[@]}"; do
    args+=(--group-add "$g")
done

# Optional extras
[ -f "$HOME/.gitconfig" ] && args+=(-v "$HOME/.gitconfig:$container_home/.gitconfig:ro")
[ -n "${ANTHROPIC_API_KEY:-}" ] && args+=(-e ANTHROPIC_API_KEY)

# shellcheck disable=SC2206
[ -n "${DOCKER_ARGS:-}" ] && args+=($DOCKER_ARGS)

exec docker run "${args[@]}" "$IMAGE" "$@"
