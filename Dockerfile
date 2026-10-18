# Three final targets share one "base" stage:
#
#   rocm     ROCm dev image + Claude Code         (BASE_IMAGE=rocm/dev-ubuntu-24.04)
#   bash     plain Ubuntu + the general dev tools in base + Rust (rustup), no GPU/board extras
#   arduino  Ubuntu + arduino-cli + ESP32 core + Claude Code (BASE_IMAGE=ubuntu:24.04)
#
# docker-bake.hcl sets BASE_IMAGE per target; "docker buildx bake" builds all.

ARG BASE_IMAGE=ubuntu:24.04
ARG DOCKER_CLI_IMAGE=docker:cli

# Static docker CLI + buildx/compose plugins, for talking to a dind daemon
# ("run.sh --dind"). Taken from the official image instead of an apt repo.
FROM ${DOCKER_CLI_IMAGE} AS docker-cli

# --------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git sudo less jq python3 python3-serial \
        openssh-client \
        build-essential cmake clang perl \
        python3-dev python3-pip python3-venv \
        librsvg2-bin python3-cairosvg fonts-dejavu-core fontconfig \
 && rm -rf /var/lib/apt/lists/*

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

# Declared after apt so a different UID/GID doesn't invalidate the apt layer.
# run.sh/bake pass your host UID/GID so files written into mounted
# workspaces end up owned by you, not by root or a random uid.
ARG USERNAME=agent
ARG UID=1000
ARG GID=1000

# Non-root user with the requested UID/GID. Ubuntu 24.04 images ship an
# "ubuntu" user at uid 1000, which would clash with most host users.
RUN set -eux; \
    if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu || userdel ubuntu; fi; \
    if getent group ubuntu >/dev/null; then groupdel ubuntu || true; fi; \
    if ! getent group "${GID}" >/dev/null; then groupadd -g "${GID}" "${USERNAME}"; fi; \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}"; \
    for g in video render dialout plugdev; do \
        if getent group "$g" >/dev/null; then usermod -aG "$g" "${USERNAME}"; fi; \
    done; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# CLAUDE_CONFIG_DIR keeps everything Claude Code stores (login, settings,
# .claude.json, history) in one directory, so a single volume persists it.
ENV HOME=/home/${USERNAME} \
    PATH=/home/${USERNAME}/.local/bin:${PATH} \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude

# Pre-create the volume mount point so a fresh named volume is owned by the user
RUN mkdir -p "${CLAUDE_CONFIG_DIR}" "${HOME}/work"

# No arguments -> claude. Arguments starting with "-" -> passed to claude.
# Anything else is run as a command (e.g. "bash").
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []

# --------------------------------------------------------------------------
FROM base AS rocm

# Claude Code, installed for the user (lands in ~/.local/bin). Kept last so
# changing CLAUDE_REFRESH ("run.sh --update") only rebuilds this layer.
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS bash

# General-purpose: python, perl, C/C++ (gcc, clang, cmake) come from base.
# Rust (rustc, cargo, clippy, rustfmt) via rustup, for the user, stable channel.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile default --default-toolchain stable \
 && "${HOME}/.cargo/bin/cargo" --version
ENV PATH=${HOME}/.cargo/bin:${PATH}

# Claude Code last, as in the other targets.
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS arduino

ARG ARDUINO_CLI_VERSION=1.5.1
ARG ARDUINO_BOARD_URLS="https://espressif.github.io/arduino-esp32/package_esp32_index.json"
ARG ARDUINO_CORES="esp32:esp32"

# arduino-cli from the official GitHub release
RUN mkdir -p "${HOME}/.local/bin" \
 && curl -fsSL "https://github.com/arduino/arduino-cli/releases/download/v${ARDUINO_CLI_VERSION}/arduino-cli_${ARDUINO_CLI_VERSION}_Linux_64bit.tar.gz" \
      | tar -xz -C "${HOME}/.local/bin" arduino-cli \
 && arduino-cli version

# Board cores (ESP32 by default)
RUN arduino-cli config init \
 && arduino-cli config set board_manager.additional_urls ${ARDUINO_BOARD_URLS} \
 && arduino-cli core update-index \
 && arduino-cli core install ${ARDUINO_CORES} \
 && arduino-cli cache clean \
 && arduino-cli core list

# Claude Code last, as in the rocm target
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

WORKDIR ${HOME}/work
