FROM rocm/dev-ubuntu-24.04:latest

# Build-time knobs. run.sh passes your host UID/GID so files written into
# mounted workspaces end up owned by you, not by root or a random uid.
ARG USERNAME=agent
ARG UID=1000
ARG GID=1000
ARG ARDUINO_CLI_VERSION=1.5.1
ARG ARDUINO_BOARD_URLS="https://espressif.github.io/arduino-esp32/package_esp32_index.json"
ARG ARDUINO_CORES="esp32:esp32"

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git sudo less jq python3 python3-serial \
 && rm -rf /var/lib/apt/lists/*

# arduino-cli from the official GitHub release
RUN curl -fsSL "https://github.com/arduino/arduino-cli/releases/download/v${ARDUINO_CLI_VERSION}/arduino-cli_${ARDUINO_CLI_VERSION}_Linux_64bit.tar.gz" \
      | tar -xz -C /usr/local/bin arduino-cli \
 && arduino-cli version

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

# Claude Code, installed for the user (lands in ~/.local/bin)
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

# Arduino board cores (ESP32 by default)
RUN arduino-cli config init \
 && arduino-cli config set board_manager.additional_urls ${ARDUINO_BOARD_URLS} \
 && arduino-cli core update-index \
 && arduino-cli core install ${ARDUINO_CORES} \
 && arduino-cli cache clean \
 && arduino-cli core list

WORKDIR /home/${USERNAME}/work

# No arguments -> claude. Arguments starting with "-" -> passed to claude.
# Anything else is run as a command (e.g. "bash").
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
