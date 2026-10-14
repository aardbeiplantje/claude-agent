# claude-agent

Claude Code in a container, on top of `rocm/dev-ubuntu-24.04`, with
`arduino-cli` and the ESP32 core preinstalled. It runs as a non-root user
that matches your host UID/GID, so files it writes in your workspace stay yours.

## Usage

```sh
cd ~/rocm-hip.git
~/claude-agent/run.sh            # builds the image on first run, then starts claude
```

- `./run.sh` starts `claude` in the current directory, mounted at `/work/<dirname>` (a trailing `.git` is dropped).
- `./run.sh --continue` passes any arguments starting with `-` to `claude`.
- `./run.sh bash` runs any other command instead of `claude`.
- `./run.sh --build` rebuilds the image, reusing the build cache.
- `./run.sh --update` pulls a fresh base image and reinstalls the latest Claude Code; if the base didn't change, only the Claude Code layer is rebuilt.

## Build caching

`run.sh` builds with `docker buildx build --load` on the `default` builder (the
docker driver). That builder uses your local image store, so the multi-GB ROCm
base is pulled once and reused. A `docker-container` builder keeps its own cache,
which buildkit garbage-collects, so it can re-download the base image. Use
`BUILDER=<name>` to pick a different builder anyway, and pass
`--build-arg BASE_IMAGE=rocm/dev-ubuntu-24.04@sha256:...` (or a ROCm version
tag) to pin the base.

## What `run.sh` sets up

- **GPU:** `/dev/kfd` and `/dev/dri/*` are passed through, and the groups that own them on your host are added automatically.
- **Serial:** any `/dev/ttyUSB*` and `/dev/ttyACM*` present at start are passed through, with their owning group. A board plugged in later needs a restart of the container.
- **Claude login and settings** persist in the Docker volume `claude-agent-claude` (`CLAUDE_CONFIG_DIR=/home/agent/.claude`).
- Your `~/.gitconfig` is mounted read-only if present, and `ANTHROPIC_API_KEY` is passed through if set.
- The ROCm-friendly flags from the old `docker run` are kept: `--ipc=host`, unconfined seccomp, unlimited memlock, a large stack and tmpfs for `/tmp` and `/var/tmp`.

The user has passwordless `sudo` inside the container.

## Configuration

| Variable        | Default                       |
|-----------------|-------------------------------|
| `WORKSPACE`     | `$PWD`                        |
| `IMAGE`         | `claude-agent:latest`         |
| `NAME`          | `claude-agent-<workspace>`    |
| `CLAUDE_VOLUME` | `claude-agent-claude`         |
| `AGENT_USER`    | `agent`                       |
| `DOCKER_ARGS`   | extra `docker run` arguments  |

Build arguments in the `Dockerfile`: `ARDUINO_CLI_VERSION`, `ARDUINO_BOARD_URLS`
and `ARDUINO_CORES` (e.g. `"esp32:esp32 arduino:avr"`).

## Example: compile and flash an ESP32 sketch

```sh
./run.sh arduino-cli compile --fqbn esp32:esp32:esp32 MySketch
./run.sh arduino-cli upload -p /dev/ttyUSB0 --fqbn esp32:esp32:esp32 MySketch
```
