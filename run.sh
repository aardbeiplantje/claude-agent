#!/bin/bash
#
# Run Claude Code in one of the claude-agent containers.
#
#   ./run.sh                    claude in the ROCm image, in the current directory
#   ./run.sh --bash             claude in the general dev image (python, perl, C/C++, Rust)
#   ./run.sh --arduino          claude in the arduino-cli/ESP32 image instead
#   ./run.sh --continue         any other args starting with "-" go to claude
#   ./run.sh bash               anything else runs as a command
#   ./run.sh --build            rebuild the selected image first (build cache kept)
#   ./run.sh --update           pull a fresh base, reinstall Claude Code, rebuild
#   ./run.sh --dind ...         give the container its own Docker daemon (dind)
#   ./run.sh --dind-stop        stop this project's dind (keeps its images)
#   ./run.sh --dind-rm          remove this project's dind, network and volume
#   ./run.sh --no-ssh-agent     don't share your ssh-agent (shared by default)
#   ./run.sh --serial           allow USB serial boards (default for --arduino)
#   ./run.sh --no-serial        don't
#
# Each project directory gets its own dind container, network and volume
# (claude-dind-<dir>-<hash>), so images and build cache are kept per project.
# The dind keeps running after claude exits; the next --dind run reuses it.
#
# Serial: access to every ttyUSB* (major 188) and ttyACM* (major 166) is
# allowed with a device cgroup rule, and the entrypoint mknods
# /dev/ttyUSB0..N and /dev/ttyACM0..N in the container. Boards plugged in or
# re-enumerated after start work without a restart. Nothing from the host's
# /dev is mounted.
#
# run.sh options (--rocm/--bash/--arduino, --build/--update, --dind...,
# --[no-]ssh-agent, --[no-]serial) come first, in any order.
# "docker buildx bake" on its own builds all images.
#
# Environment overrides:
#   WORKSPACE      host directory to work in        (default: $PWD)
#   IMAGE_REPO     image repository                  (default: claude-agent)
#   IMAGE          full image tag                    (default: $IMAGE_REPO:<rocm|bash|arduino>)
#   NAME           container name                    (default: claude-agent-<flavor>-<workspace>)
#   CLAUDE_VOLUME  volume (or absolute host path) for ~/.claude: login,
#                  settings, permissions             (default: claude-agent-claude, shared)
#   SSH_AGENT      1 shares $SSH_AUTH_SOCK, 0 doesn't (default: 1)
#   SSH_KNOWN_HOSTS 1 also mounts your ~/.ssh/known_hosts read-only (default: 0)
#   SERIAL         1 allows serial boards, 0 doesn't (default: 1 for arduino, 0 for rocm)
#   SERIAL_MAX     device nodes created per serial type (default: 8)
#   AGENT_USER     user name inside the image        (default: agent)
#   BUILDER        buildx builder to build with      (default: the active one)
#   DIND_IMAGE     dind image                        (default: docker:dind)
#   DOCKER_ARGS    extra "docker run" arguments, word-split
#
set -euo pipefail

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

flavor=rocm
build=0
dind=
ssh_agent=${SSH_AGENT:-1}
serial=${SERIAL:-}
refresh=()
while [ $# -gt 0 ]; do
    case "$1" in
        --rocm)    flavor=rocm ;;
        --bash)    flavor=bash ;;
        --arduino) flavor=arduino ;;
        --build)   build=1 ;;
        --update)  build=1; refresh=(--pull) ;;
        --dind)      dind='run' ;;
        --dind-stop) dind='stop' ;;
        --dind-rm)   dind='rm' ;;
        --ssh-agent)    ssh_agent=1 ;;
        --no-ssh-agent) ssh_agent=0 ;;
        --serial)    serial=1 ;;
        --no-serial) serial=0 ;;
        *) break ;;
    esac
    shift
done

IMAGE_REPO=${IMAGE_REPO:-claude-agent}
IMAGE=${IMAGE:-$IMAGE_REPO:$flavor}
WORKSPACE=$(readlink -f "${WORKSPACE:-$PWD}")
CLAUDE_VOLUME=${CLAUDE_VOLUME:-claude-agent-claude}
AGENT_USER=${AGENT_USER:-agent}
BUILDER=${BUILDER:-}
SERIAL_MAX=${SERIAL_MAX:-8}
if [ -z "$serial" ]; then
    [ "$flavor" = arduino ] && serial=1 || serial=0
fi

# ~/rocm-hip.git -> /work/rocm-hip
ws_name=$(basename "$WORKSPACE")
ws_name=${ws_name%.git}
NAME=${NAME:-claude-agent-$flavor-$(tr -c 'a-zA-Z0-9_.\n-' '-' <<<"$ws_name")}
container_home=/home/$AGENT_USER
container_ws=/work/$ws_name

# Per-project dind: name from the directory plus a short hash of its full
# path, so two checkouts with the same name don't share a daemon.
ws_key=$(tr -c 'a-zA-Z0-9_.\n-' '-' <<<"$ws_name")-$(printf %s "$WORKSPACE" | sha256sum | cut -c1-8)
DIND_IMAGE=${DIND_IMAGE:-docker:dind}
dind_name=claude-dind-$ws_key
dind_volume=claude-dind-$ws_key
dind_network=claude-agent-$ws_key

case "$dind" in
    stop)
        docker stop "$dind_name"
        exit ;;
    rm)
        docker rm -f "$dind_name" 2>/dev/null || true
        docker network rm "$dind_network" 2>/dev/null || true
        docker volume rm "$dind_volume"
        exit ;;
esac

# The image user can't be root; fall back to 1000 if run as root.
uid=$(id -u); gid=$(id -g)
[ "$uid" = 0 ] && uid=1000
[ "$gid" = 0 ] && gid=1000

if [ "$build" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    # docker-bake.hcl holds the build definition. Uses the same builder as a
    # plain "docker buildx bake" (the active one) unless BUILDER is set, so
    # both share one build cache.
    claude_refresh=${CLAUDE_REFRESH:-0}
    [ ${#refresh[@]} -gt 0 ] && claude_refresh=$(date +%s)
    (
        cd "$here"
        IMAGE_REPO=$IMAGE_REPO AGENT_USER=$AGENT_USER \
        AGENT_UID=$uid AGENT_GID=$gid CLAUDE_REFRESH=$claude_refresh \
            docker buildx bake ${BUILDER:+--builder "$BUILDER"} "${refresh[@]}" \
                --set "$flavor.tags=$IMAGE" "$flavor"
    )
fi

# shellcheck disable=SC2054  # commas in --tmpfs options are intentional
args=(
    --rm
    --init
    --name "$NAME"
    --hostname "$NAME"
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

case "$flavor" in
    rocm)
        add_dev /dev/kfd                              # ROCm compute
        for d in /dev/dri/card* /dev/dri/renderD*; do # GPU
            add_dev "$d"
        done
        args+=(
            --security-opt seccomp=unconfined
            --ipc=host
            --ulimit memlock=-1:-1
            --ulimit stack=67108864:67108864
        )
        ;;
esac
for g in "${!gids[@]}"; do
    args+=(--group-add "$g")
done

# Serial boards: allow whole device types (name:major), not single devices,
# so boards plugged in later work too. The entrypoint creates the nodes.
# Don't add ttyS (major 4): it shares its major with the virtual consoles.
if [ "$serial" = 1 ]; then
    serial_types=(ttyUSB:188 ttyACM:166)
    for t in "${serial_types[@]}"; do
        args+=(--device-cgroup-rule "c ${t#*:}:* rmw")
    done
    args+=(-e "SERIAL_NODES=${serial_types[*]}" -e "SERIAL_MAX=$SERIAL_MAX")
fi

if [ "$dind" = run ]; then
    docker network inspect "$dind_network" >/dev/null 2>&1 \
        || docker network create "$dind_network" >/dev/null
    case "$(docker inspect -f '{{.State.Running}}' "$dind_name" 2>/dev/null || true)" in
        true)  ;;
        false) docker start "$dind_name" >/dev/null ;;
        *)
            # TLS off: the daemon listens on tcp://dind:2375, reachable only on
            # this project's private network. The workspace is mounted at the
            # same path as in the agent, so "docker run -v /work/..." works.
            docker run -d --privileged \
                --name "$dind_name" \
                --hostname "$dind_name" \
                --network "$dind_network" \
                --network-alias dind \
                -e DOCKER_TLS_CERTDIR= \
                -v "$dind_volume:/var/lib/docker" \
                -v "$WORKSPACE:$container_ws" \
                --label claude-agent.workspace="$WORKSPACE" \
                "$DIND_IMAGE" >/dev/null
            ;;
    esac
    echo "waiting for $dind_name ..." >&2
    for _ in $(seq 1 60); do
        docker exec "$dind_name" docker info >/dev/null 2>&1 && break
        sleep 1
    done
    docker exec "$dind_name" docker info >/dev/null 2>&1 \
        || { echo "dind $dind_name did not come up; see: docker logs $dind_name" >&2; exit 1; }
    args+=(--network "$dind_network" -e DOCKER_HOST=tcp://dind:2375)
fi

# Optional extras
[ -f "$HOME/.gitconfig" ] && args+=(-v "$HOME/.gitconfig:$container_home/.gitconfig:ro")
[ -n "${ANTHROPIC_API_KEY:-}" ] && args+=(-e ANTHROPIC_API_KEY)

# ssh-agent: the socket is mounted, never the keys. The container user has
# your UID, so it can use the socket.
# accept-new trusts unknown hosts on first use (changed keys still fail), so a
# restart never stops at a host key prompt. Your host known_hosts is NOT
# mounted by default: one outdated entry there (e.g. GitHub's old RSA key)
# would turn "unknown, accept" into "changed, refuse". SSH_KNOWN_HOSTS=1
# mounts it read-only as the system-wide file anyway.
if [ "$ssh_agent" = 1 ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
    args+=(-v "$SSH_AUTH_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock
        -e "GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o StrictHostKeyChecking=accept-new}")
    [ "${SSH_KNOWN_HOSTS:-0}" = 1 ] && [ -f "$HOME/.ssh/known_hosts" ] \
        && args+=(-v "$HOME/.ssh/known_hosts:/etc/ssh/ssh_known_hosts:ro")
fi

# shellcheck disable=SC2206
[ -n "${DOCKER_ARGS:-}" ] && args+=($DOCKER_ARGS)

exec docker run "${args[@]}" "$IMAGE" "$@"
