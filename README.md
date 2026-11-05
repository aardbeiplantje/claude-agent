# claude-agent

Claude Code in a container, in three independent images built from one Dockerfile:

| Image                  | Base                           | Adds                                   |
|------------------------|--------------------------------|-----------------------------------------|
| `claude-agent:rocm`    | `rocm/dev-ubuntu-24.04:latest` | Rust (rustup), Claude Code              |
| `claude-agent:bash`    | `ubuntu:24.04`                 | Rust (rustup), Node.js, Go, Claude Code |
| `claude-agent:arduino` | `ubuntu:24.04`                 | arduino-cli, ESP32 core, usb_logger, Claude Code |
| `claude-agent:android` | `ubuntu:24.04`                 | JDK 17, Android SDK (platform, build-tools, adb), Gradle, Claude Code |

None depends on the others. All include python3 (pip, venv, pipx, `python` alias), perl, lua 5.4 / luajit (luarocks), gcc/g++, clang (clang-format, clang-tidy, lld), cmake, ninja, make, autotools, ccache, bear, gdb, valgrind, strace, common -dev libraries (openssl, zlib, ffi, sqlite), ripgrep, fd, shellcheck, shfmt, git-lfs and basic network tools. The `rocm` and `bash` images also have Rust (`rustc`, `cargo`, `clippy`, `rustfmt`, stable via rustup), and the `bash` image has Node.js/npm and Go (Ubuntu packages). Both run as a non-root user that matches your host
UID/GID, so files they write in your workspace stay yours.

## Usage

```sh
cd ~/rocm-hip.git
~/claude-agent/run.sh             # claude in the ROCm image (builds it on first run)
~/claude-agent/run.sh --bash      # claude in the general dev image, no GPU or board extras
~/claude-agent/run.sh --arduino   # claude in the arduino image
~/claude-agent/run.sh --android   # claude in the android image
```

- The current directory is mounted at `/work/<dirname>` (a trailing `.git` is dropped).
- `--rocm` (default), `--bash` or `--arduino` selects the image.
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
`AGENT_UID`, `AGENT_GID`, `CLAUDE_REFRESH`, `ARDUINO_CLI_VERSION`, `ARDUINO_BOARD_URLS`,
`ARDUINO_CORES` (e.g. `"esp32:esp32 arduino:avr"`), `USB_METER_VERSION` (the
`usb-multimeter` release on PyPI), and for the android image `ANDROID_CMDLINE_TOOLS` (the
build number in the command-line tools zip), `ANDROID_PLATFORM`, `ANDROID_BUILD_TOOLS` and
`GRADLE_VERSION`. Set
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
- The dind runs `--privileged`, and has no GPU, serial or USB devices. Its image store is separate
  from your host's, so building the ROCm image in there pulls the ~30 GB base again.

## What `run.sh` sets up

- **ROCm image:** `/dev/kfd` and `/dev/dri/*` are passed through, and the groups that own them on your host are added automatically. It keeps the ROCm flags from the old `docker run`: `--ipc=host`, unconfined seccomp, unlimited memlock and a large stack.
- **Serial boards** (default for `--arduino`, opt-in with `--serial` for ROCm): a device cgroup rule allows all `ttyUSB*` (major 188) and `ttyACM*` (major 166) devices, and the entrypoint creates `/dev/ttyUSB0..7` and `/dev/ttyACM0..7` (group `dialout`) inside the container. Boards plugged in, or renumbered after a reset, while the container runs work without a restart. Nothing from the host's `/dev` is mounted. The nodes always exist, so use `arduino-cli board list` (which reads `/sys`) to see what's actually connected. A node with no board behind it fails to open with "No such device or address". `/dev/serial/by-id` doesn't exist (no udev). Turn it off with `--no-serial` or `SERIAL=0`.
- **USB power meters** (opt-in with `--usb` or `USB=1`, any image): a device cgroup rule allows USB char major 189, and the entrypoint mknods `/dev/bus/usb/<bus>/<dev>` for each supported meter, owned by the container's `dialout` group, the same way it makes the serial nodes. Nothing from the host's `/dev` is mounted. A meter replugged while the container runs needs `usb-meter-nodes` run again. The rule lets the container open every USB device on the host, which is why it's opt-in. See [USB power meters](#usb-power-meters-jt-um120-fnirsi).
- **Both:** Claude's login and settings persist in the shared Docker volume `claude-agent-claude` (`CLAUDE_CONFIG_DIR=/home/agent/.claude`), so you log in once. That includes `settings.json`, so permissions you save as user settings with `/permissions` stick across runs (project-level ones go to `.claude/` in the workspace, which is your own directory). Set `CLAUDE_VOLUME=$HOME/.claude-agent` (an absolute path) to use a host directory instead, so you can edit the settings from the host. `/tmp` and `/var/tmp` are tmpfs. Your `~/.gitconfig` is mounted read-only if present, and `ANTHROPIC_API_KEY` is passed through if set.
- **ssh-agent:** if `SSH_AUTH_SOCK` is set, the agent's socket is mounted (not your keys), so `git` and `ssh` inside can use your keys. `GIT_SSH_COMMAND` is set to `ssh -o StrictHostKeyChecking=accept-new` (override by exporting your own) so new hosts are accepted without a prompt (a changed host key still fails). Your host `known_hosts` is deliberately not mounted, because one stale entry there would block every push; set `SSH_KNOWN_HOSTS=1` to mount it read-only anyway. Turn it off with `--no-ssh-agent` or `SSH_AGENT=0`. This is Linux-only: on Docker Desktop for Mac the host socket path can't be mounted.

The user has passwordless `sudo` inside the containers.

## Configuration

| Variable        | Default                                 |
|-----------------|-----------------------------------------|
| `WORKSPACE`     | `$PWD`                                  |
| `IMAGE_REPO`    | `claude-agent`                          |
| `IMAGE`         | `$IMAGE_REPO:rocm`, `:bash`, `:arduino` |
| `NAME`          | `claude-agent-<flavor>-<workspace>`     |
| `CLAUDE_VOLUME` | `claude-agent-claude`                   |
| `AGENT_USER`    | `agent`                                 |
| `SSH_AGENT`     | `1` (share `$SSH_AUTH_SOCK`)            |
| `SSH_KNOWN_HOSTS` | `0` (`1` mounts your known_hosts)     |
| `SERIAL`        | `1` for arduino, `0` for rocm           |
| `SERIAL_MAX`    | `8` nodes per serial type               |
| `USB`           | `0` (`1` allows USB power meters)       |
| `BUILDER`       | active buildx builder                   |
| `DIND_IMAGE`    | `docker:dind`                           |
| `DOCKER_ARGS`   | extra `docker run` arguments            |

## Example: compile and flash an ESP32 sketch

```sh
./run.sh --arduino arduino-cli compile --fqbn esp32:esp32:esp32 MySketch
./run.sh --arduino arduino-cli upload -p /dev/ttyUSB0 --fqbn esp32:esp32:esp32 MySketch
```

## USB power meters (JT-UM120, FNIRSI)

The arduino image has `usb_logger` from [rsfzi/JT-UM120-usb-power-data-logger](https://github.com/rsfzi/JT-UM120-usb-power-data-logger)
(PyPI `usb-multimeter`), for the JT-UM120 (`2e3c:5558`, the Joy-IT meter), FNIRSI FNB48, FNB48S, C1 and FNB58.
The meters are HID devices, not serial ports, so they need `--usb`:

```sh
./run.sh --arduino --usb
usb_logger device list
usb_logger device show --id 2e3c:5558
usb_logger log --id 2e3c:5558 --duration 60s -o power.csv
```

- **No host setup.** The container makes its own node for the meter, the same way it makes
  the serial ones, so the host's permissions on the device don't matter and the project's
  udev rule isn't needed. `usb-meter-nodes` finds each supported meter in `/sys` and mknods
  `/dev/bus/usb/<bus>/<dev>` (char 189, minor `(bus-1)*128 + (dev-1)`, group `dialout`). It
  runs at container start. After replugging a meter, run `usb-meter-nodes` again.
  `USB_METER_IDS="vid:pid ..."` changes which meters it looks for.
- The kernel's `usb-storage` and `FAT` driver also claim the FNB58's mass-storage interface.
  That's the meter's built-in log (CFN format), not the data `usb_logger` reads, and it's
  unrelated to the container.
- Tested on one host with a JT-UM120 (`2e3c:5558`): after a container restart, `usb_logger
  device list`, `device show` and a 5-second `log` all work as the agent user, with no sudo.
  Only the JT-UM120 has been tried. The FNB48, FNB48S, C1 and FNB58 IDs are in the default
  list but untested. Other hosts and container runtimes (rootless Docker, podman) are untested
  too: they need device cgroup rules and `CAP_MKNOD`.

## Android development

The android image has JDK 17, the Android SDK command-line tools with `android-35` and
build-tools `35.0.0` (set with `ANDROID_PLATFORM` and `ANDROID_BUILD_TOOLS`), `adb`, and
Gradle 8.14.6. The SDK lives in `~/android-sdk` and Gradle in `~/gradle-8.14.6`, both on
`PATH`, so `sdkmanager` can add platforms without root:

```sh
./run.sh --android
sdkmanager "platforms;android-36"       # any other platform, from inside the container
```

Phones aren't passed through over USB, so use wireless debugging: on the phone, enable
Developer options, then Wireless debugging, and use the IP and ports it shows:

```sh
adb pair 192.168.1.50:37123             # pairing code from the phone
adb connect 192.168.1.50:41234          # the connect port, which differs from the pairing port
adb devices
```

The container is on Docker's bridge network, so the phone has to be on a network the host
can reach. `adb`'s mDNS discovery doesn't work from a bridge network, so use the IP and port.
