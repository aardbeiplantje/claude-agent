# Build definitions for the claude-agent images.
#
#   docker buildx bake                 build all images into the local image store
#   docker buildx bake rocm            only claude-agent:rocm
#   docker buildx bake arduino         only claude-agent:arduino
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

variable "ROCM_IMAGE" {
  # Pin to a digest or ROCm version tag for reproducible builds.
  default = "rocm/dev-ubuntu-24.04:latest"
}

variable "UBUNTU_IMAGE" {
  default = "ubuntu:24.04"
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

variable "ARDUINO_CLI_VERSION" {
  default = "1.5.1"
}

variable "ARDUINO_BOARD_URLS" {
  default = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
}

variable "ARDUINO_CORES" {
  default = "esp32:esp32"
}

group "default" {
  targets = ["local"]
}

# Everything, loaded into the local image store
group "local" {
  targets = ["rocm", "arduino"]
}

# Shared settings; the leading underscore marks it as not meant to be built alone
target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    USERNAME       = AGENT_USER
    UID            = AGENT_UID
    GID            = AGENT_GID
    CLAUDE_REFRESH = CLAUDE_REFRESH
  }
  # Load into the local image store (like "docker build --load"),
  # so "docker run" and run.sh can see the result.
  output = ["type=docker"]
}

target "rocm" {
  inherits = ["_common"]
  target   = "rocm"
  tags     = ["${IMAGE_REPO}:rocm"]
  args = {
    BASE_IMAGE = ROCM_IMAGE
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
  }
}
