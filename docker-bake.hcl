# Build definition for the claude-agent image.
#
#   docker buildx bake                 build claude-agent:latest (cached)
#   docker buildx bake update          pull a fresh base, reinstall Claude Code
#   docker buildx bake --print         show the resolved configuration
#
# Every variable can be overridden from the environment, e.g.
#   AGENT_UID=$(id -u) AGENT_GID=$(id -g) docker buildx bake
# run.sh sets AGENT_UID/AGENT_GID to your host ids for you. (Bash's UID is a
# non-exported shell variable, hence the AGENT_ prefix.)

variable "IMAGE" {
  default = "claude-agent:latest"
}

variable "BASE_IMAGE" {
  # Pin to a digest or ROCm version tag for reproducible builds.
  default = "rocm/dev-ubuntu-24.04:latest"
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
  targets = ["agent"]
}

target "agent" {
  context    = "."
  dockerfile = "Dockerfile"
  tags       = [IMAGE]
  platforms  = ["linux/amd64"]
  args = {
    BASE_IMAGE          = BASE_IMAGE
    USERNAME            = AGENT_USER
    UID                 = AGENT_UID
    GID                 = AGENT_GID
    ARDUINO_CLI_VERSION = ARDUINO_CLI_VERSION
    ARDUINO_BOARD_URLS  = ARDUINO_BOARD_URLS
    ARDUINO_CORES       = ARDUINO_CORES
  }
  # Load into the local image store (same as "docker build --load"),
  # so "docker run" and run.sh can see the result.
  output = ["type=docker"]
}

# Re-pull the base image and bust only the Claude Code layer; apt, arduino-cli
# and the esp32 toolchains stay cached unless the base itself changed.
target "update" {
  inherits = ["agent"]
  pull     = true
  args = {
    CLAUDE_REFRESH = timestamp()
  }
}
