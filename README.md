# claude-agent

Claude Code in a container, in two independent images built from one Dockerfile:

| Image                  | Base                           | Adds                                   |
|------------------------|--------------------------------|----------------------------------------|
| `claude-agent:rocm`    | `rocm/dev-ubuntu-24.04:latest` | Claude Code                            |
| `claude-agent:arduino` | `ubuntu:24.04`                 | arduino-cli, ESP32 core, Claude Code   |

Neither depends on the other. Both run as a non-root user that matches your host
UID/GID, so files they write in your workspace stay yours.

## Usage

```sh
cd ~/rocm-hip.git
~/claude-agent/run.sh             # claude in the ROCm image (builds it on first run)
~/claude-agent/run.sh --arduino   # claude in the arduino image
```

- The current directory is mounted at `/work/<dirname>` (a trailing `.git` is dropped).
- `--rocm` (default) or `--arduino` selects the image.
- `--build` rebuilds the selected image, reusing the build cache.
- `--update` pulls a fresh base image and reinstalls the latest Claude Code. If the base didn't change, only the Claude Code layer is rebuilt.
- After those options, arguments starting with `-` go to `claude` (`./run.sh --continue`). Anything else runs as a command (`./run.sh --arduino bash`).

## Building

The build is defined in `docker-bake.hcl`. `run.sh` builds the image it needs, or run bake directly:

```sh
export AGENT_UID=$(id -u) AGENT_GID=$(id -g)
docker buildx bake                                   # all images ("local" group), into your local images
docker buildx bake rocm                              # just one
CLAUDE_REFRESH=$(date +%s) docker buildx bake --pull # fresh bases + latest Claude Code
docker buildx bake --print                           # show the resolved config
```

Overridable variables: `IMAGE_REPO`, `ROCM_IMAGE`, `UBUNTU_IMAGE`, `AGENT_USER`,
`AGENT_UID`, `AGENT_GID`, `CLAUDE_REFRESH`, `ARDUINO_CLI_VERSION`, `ARDUINO_BOARD_URLS`
and `ARDUINO_CORES` (e.g. `"esp32:esp32 arduino:avr"`). Set
`ROCM_IMAGE=rocm/dev-ubuntu-24.04@sha256:...` (or a ROCm version tag) to pin the base.

Both `run.sh` and a plain `docker buildx bake` use your active builder (`BUILDER=<name>`
overrides it for `run.sh`), so they share one build cache. Plain `bake` builds with UID/GID 1000
unless `AGENT_UID`/`AGENT_GID` are exported; if your ids differ, export them in your shell
profile, or the two will build separate user layers.

With a `docker-container` builder, every build exports the image as a tarball and loads it
into Docker, and the builder keeps its own cache that BuildKit garbage-collects. The ROCm
base is tens of GB, so with the default GC limits the cache can be evicted between builds.
Either raise the builder's GC limits (`buildkitd.toml`), or build with the `default` builder
(docker driver), which builds straight into the local image store with no export step:

```sh
docker buildx bake --builder default
```

## Docker inside the container (dind)

`--dind` gives the container its own Docker daemon, so Claude can build and run
images (including these ones) without access to your host's Docker:

```sh
cd ~/claude-agent.git
./run.sh --dind claude remote-control --spawn worktree
```

- Each project directory gets its own `docker:dind` container, network and volume, named
  `claude-dind-<dir>-<hash>`, so images and build cache stay separate per project.
- Inside, `DOCKER_HOST=tcp://dind:2375` points `docker` and `docker buildx` at it. The daemon
  only listens on that project's private network.
- The project is also mounted in the dind at the same `/work/<dir>` path, so
  `docker run -v /work/<dir>/...` from inside works.
- The dind keeps running after Claude exits, and the next `--dind` run reuses it.
  `./run.sh --dind-stop` stops it; `./run.sh --dind-rm` removes it along with its network
  and volume (all its images).
- The dind runs `--privileged`, and has no GPU or serial devices. Its image store is separate
  from your host's, so building the ROCm image in there pulls the ~30 GB base again.

## What `run.sh` sets up

- **ROCm image:** `/dev/kfd` and `/dev/dri/*` are passed through, and the groups that own them on your host are added automatically. It keeps the ROCm flags from the old `docker run`: `--ipc=host`, unconfined seccomp, unlimited memlock and a large stack.
- **Arduino image:** any `/dev/ttyUSB*` and `/dev/ttyACM*` present at start are passed through, with their owning group. A board plugged in later needs a restart of the container.
- **Both:** Claude's login and settings persist in the shared Docker volume `claude-agent-claude` (`CLAUDE_CONFIG_DIR=/home/agent/.claude`), so you log in once. `/tmp` and `/var/tmp` are tmpfs. Your `~/.gitconfig` is mounted read-only if present, and `ANTHROPIC_API_KEY` is passed through if set.

The user has passwordless `sudo` inside the containers.

## Configuration

| Variable        | Default                                 |
|-----------------|-----------------------------------------|
| `WORKSPACE`     | `$PWD`                                  |
| `IMAGE_REPO`    | `claude-agent`                          |
| `IMAGE`         | `$IMAGE_REPO:rocm` or `:arduino`        |
| `NAME`          | `claude-agent-<flavor>-<workspace>`     |
| `CLAUDE_VOLUME` | `claude-agent-claude`                   |
| `AGENT_USER`    | `agent`                                 |
| `BUILDER`       | active buildx builder                   |
| `DIND_IMAGE`    | `docker:dind`                           |
| `DOCKER_ARGS`   | extra `docker run` arguments            |

## Example: compile and flash an ESP32 sketch

```sh
./run.sh --arduino arduino-cli compile --fqbn esp32:esp32:esp32 MySketch
./run.sh --arduino arduino-cli upload -p /dev/ttyUSB0 --fqbn esp32:esp32:esp32 MySketch
```
