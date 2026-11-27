# Build definitions for the claude-agent images.
#
#   docker buildx bake                 build all images into the local image store
#   docker buildx bake rocm            only claude-agent:rocm
#   docker buildx bake bash            only claude-agent:bash (basic)
#   docker buildx bake dev             only claude-agent:dev (full dev: Rust, Node.js, Go, rtl-sdr)
#   docker buildx bake arduino         only claude-agent:arduino
#   docker buildx bake android         only claude-agent:android
#   docker buildx bake web             only claude-agent:web
#   docker buildx bake hailo           only claude-agent:hailo (Raspberry Pi 5 only, arm64)
#   DOCKER_PLATFORM=linux/arm64 docker buildx bake   the arm64 set (default linux/amd64)
#   docker buildx bake --print         show the resolved configuration
#
# Refresh: pull fresh base images and reinstall Claude Code (only the Claude
# Code layer is rebuilt when a base image didn't change):
#   CLAUDE_REFRESH=$(date +%s) docker buildx bake --pull
#
# Every variable can be overridden from the environment, e.g.
#   AGENT_UID=$(id -u) AGENT_GID=$(id -g) docker buildx bake
# run.sh sets AGENT_UID/AGENT_GID to your host ids for you. (Bash's UID is a
# non-exported shell variable, hence the AGENT_ prefix.)

variable "IMAGE_REPO" {
  default = "claude-agent"
}

# Image platform: linux/amd64 (default) or linux/arm64. run.sh sets it to the
# host's architecture. rocm and android are amd64 only, so they are not built
# for arm64.
variable "DOCKER_PLATFORM" {
  default = "linux/amd64"
}

variable "ROCM_IMAGE" {
  # Pin to a digest or ROCm version tag for reproducible builds.
  default = "rocm/dev-ubuntu-24.04:latest"
}

variable "UBUNTU_IMAGE" {
  default = "ubuntu:24.04"
}

variable "DEBIAN_IMAGE" {
  # bookworm: the release the Raspberry Pi OS and its Hailo packages are built for
  default = "debian:bookworm-slim"
}

variable "AGENT_USER" {
  default = "agent"
}

variable "AGENT_UID" {
  default = "1000"
}

variable "AGENT_GID" {
  default = "1000"
}

variable "CLAUDE_REFRESH" {
  default = "0"
}

variable "NRFUTIL_REFRESH" {
  default = "0"
}

variable "TORCH_INDEX" {
  # TheRock nightly index for one GPU family (gfx1151 = Strix Halo)
  default = "https://rocm.nightlies.amd.com/v2/gfx1151/"
}

variable "TORCH_VERSION" {
  default = "2.9.1+rocm7.13.0a20260513"
}

variable "TORCHVISION_VERSION" {
  default = "0.24.0+rocm7.13.0a20260513"
}

variable "TORCHAUDIO_VERSION" {
  default = "2.9.0+rocm7.13.0a20260513"
}

variable "ARDUINO_CLI_VERSION" {
  default = "1.5.1"
}

variable "ARDUINO_BOARD_URLS" {
  default = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
}

variable "ARDUINO_CORES" {
  default = "esp32:esp32"
}

variable "USB_METER_VERSION" {
  # usb-multimeter on PyPI (usb_logger)
  default = "3.0.0"
}

variable "ANDROID_CMDLINE_TOOLS" {
  # build number in commandlinetools-linux-<n>_latest.zip (developer.android.com/studio)
  default = "15859902"
}

variable "ANDROID_PLATFORM" {
  default = "android-35"
}

variable "ANDROID_BUILD_TOOLS" {
  default = "35.0.0"
}

variable "GRADLE_VERSION" {
  default = "8.14.6"
}

variable "NODE_VERSION" {
  # Node.js release from nodejs.org (22.x is LTS)
  default = "22.11.0"
}

variable "PLAYWRIGHT_VERSION" {
  # npm "playwright" package; its Firefox build is installed with it
  default = "1.56.1"
}

group "default" {
  targets = ["local"]
}

# Everything for the platform, loaded into the local image store. On arm64 the
# amd64-only images (rocm, android) are left out, and hailo (Raspberry Pi 5) is
# added; on amd64 hailo is left out.
group "local" {
  targets = DOCKER_PLATFORM == "linux/arm64" ? ["bash", "dev", "arduino", "web", "hailo"] : ["rocm", "bash", "dev", "arduino", "android", "web"]
}

# Shared settings; the leading underscore marks it as not meant to be built alone
target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = [DOCKER_PLATFORM]
  args = {
    USERNAME = AGENT_USER
    UID      = AGENT_UID
    GID      = AGENT_GID
    CLAUDE_REFRESH   = CLAUDE_REFRESH
  }
  # Load into the local image store (like "docker build --load"),
  # so "docker run" and run.sh can see the result.
  output = ["type=docker"]
}

target "rocm" {
  inherits = ["_common"]
  target   = "rocm"
  platforms = ["linux/amd64"]
  tags     = ["${IMAGE_REPO}:rocm"]
  args = {
    BASE_IMAGE          = ROCM_IMAGE
    TORCH_INDEX         = TORCH_INDEX
    TORCH_VERSION       = TORCH_VERSION
    TORCHVISION_VERSION = TORCHVISION_VERSION
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION
  }
}

target "bash" {
  inherits = ["_common"]
  target   = "bash"
  tags     = ["${IMAGE_REPO}:bash"]
  args = {
    BASE_IMAGE = UBUNTU_IMAGE
  }
}

target "dev" {
  inherits = ["_common"]
  target   = "dev"
  tags     = ["${IMAGE_REPO}:dev"]
  args = {
    BASE_IMAGE = UBUNTU_IMAGE
  }
}

target "arduino" {
  inherits = ["_common"]
  target   = "arduino"
  tags     = ["${IMAGE_REPO}:arduino"]
  args = {
    BASE_IMAGE          = UBUNTU_IMAGE
    ARDUINO_CLI_VERSION = ARDUINO_CLI_VERSION
    ARDUINO_BOARD_URLS  = ARDUINO_BOARD_URLS
    ARDUINO_CORES       = ARDUINO_CORES
    USB_METER_VERSION   = USB_METER_VERSION
    NRFUTIL_REFRESH     = NRFUTIL_REFRESH
  }
}

target "android" {
  inherits = ["_common"]
  target   = "android"
  platforms = ["linux/amd64"]
  tags     = ["${IMAGE_REPO}:android"]
  args = {
    BASE_IMAGE            = UBUNTU_IMAGE
    ANDROID_CMDLINE_TOOLS = ANDROID_CMDLINE_TOOLS
    ANDROID_PLATFORM      = ANDROID_PLATFORM
    ANDROID_BUILD_TOOLS   = ANDROID_BUILD_TOOLS
    GRADLE_VERSION        = GRADLE_VERSION
  }
}

target "web" {
  inherits = ["_common"]
  target   = "web"
  tags     = ["${IMAGE_REPO}:web"]
  args = {
    BASE_IMAGE         = UBUNTU_IMAGE
    NODE_VERSION       = NODE_VERSION
    PLAYWRIGHT_VERSION = PLAYWRIGHT_VERSION
  }
}

target "hailo" {
  inherits = ["_common"]
  target   = "hailo"
  platforms = ["linux/arm64"]
  tags     = ["${IMAGE_REPO}:hailo"]
  args = {
    BASE_IMAGE = DEBIAN_IMAGE
  }
}
