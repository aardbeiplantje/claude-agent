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
- `./run.sh --build` rebuilds the image with a freshly pulled base image (do this to update ROCm or Claude Code).

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
