# Three final targets share one "base" stage:
#
#   rocm     ROCm dev image + Rust (rustup) + Claude Code  (BASE_IMAGE=rocm/dev-ubuntu-24.04)
#   bash     plain Ubuntu + the general dev tools in base + Rust (rustup), no GPU/board extras
#   arduino  Ubuntu + arduino-cli + ESP32 core + usb_logger (USB power meters)
#            + Claude Code (BASE_IMAGE=ubuntu:24.04)
#   android  Ubuntu + JDK 17 + Android SDK (platform, build-tools, platform-tools)
#            + Gradle + Claude Code (BASE_IMAGE=ubuntu:24.04)
#
# docker-bake.hcl sets BASE_IMAGE per target; "docker buildx bake" builds all.

ARG BASE_IMAGE=ubuntu:24.04

# --------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git sudo less jq python3 python3-serial \
        openssh-client \
        build-essential cmake ninja-build clang perl \
        lua5.4 luajit python-is-python3 \
        python3-dev python3-pip python3-venv \
        librsvg2-bin python3-cairosvg fonts-dejavu-core fontconfig \
        ripgrep fd-find file tree zip unzip xz-utils rsync wget patch \
        diffutils procps htop strace lsof git-lfs \
        gdb valgrind clang-format clang-tidy lld ccache pkg-config \
        autoconf automake libtool libtool-bin bear \
        libssl-dev zlib1g-dev libffi-dev libsqlite3-dev sqlite3 \
        liblua5.4-dev luarocks pipx shellcheck shfmt \
        iproute2 iputils-ping dnsutils netcat-openbsd socat \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

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
COPY --chmod=0755 usb-meter-nodes.sh /usr/local/bin/usb-meter-nodes

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

# Rust (rustc, cargo, clippy, rustfmt) via rustup, for the user, stable channel.
# Same as in the bash target.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile default --default-toolchain stable \
 && "${HOME}/.cargo/bin/cargo" --version
ENV PATH=${HOME}/.cargo/bin:${PATH}

# Claude Code, installed for the user (lands in ~/.local/bin). Kept last so
# changing CLAUDE_REFRESH ("run.sh --update") only rebuilds this layer.
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS bash

# General-purpose: python, perl, lua/luajit, C/C++ (gcc, clang, cmake, ninja)
# come from base.
# Node.js (+ npm) and Go from Ubuntu's apt. ARGs don't carry across stages,
# hence USERNAME again (same default as in base).
ARG USERNAME=agent
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm golang-go \
        rtl-sdr \
 && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}

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

# usb_logger for the JT-UM120 / FNIRSI USB power meters, from PyPI (the
# rsfzi/JT-UM120-usb-power-data-logger project), into ~/.local/bin via pipx.
# pyusb talks to the meter through libusb, which needs its shared library.
# ARGs don't carry across stages, hence USERNAME again.
ARG USERNAME=agent
ARG USB_METER_VERSION=3.0.0
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends libusb-1.0-0 rtl-sdr tshark \
 && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}
RUN pipx install "usb-multimeter==${USB_METER_VERSION}" \
 && usb_logger --help >/dev/null

# Nordic's nrfutil (the launcher; pinned by sha256) plus its device and
# ble-sniffer commands. device flashes the nRF52840 Dongle's sniffer firmware
# (nrfutil device program --traits nordicDfu --firmware <zip>), and ble-sniffer
# reads the sniffer's serial output (nrfutil ble-sniffer sniff --port ...).
ARG NRFUTIL_URL="https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/x86_64-unknown-linux-gnu/nrfutil-x86_64-unknown-linux-gnu-1.4.2-8a9090a"
ARG NRFUTIL_SHA256=a14996288928a92081cadeefd2dd37fcb54ee99a568fd4eaa6fb9586a51fba57
ARG NRFUTIL_DEVICE=device=2.17.5
ARG NRFUTIL_BLE_SNIFFER=ble-sniffer=0.18.0
USER root
RUN curl -fsSL -o /usr/local/bin/nrfutil "${NRFUTIL_URL}" \
 && echo "${NRFUTIL_SHA256}  /usr/local/bin/nrfutil" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/nrfutil
USER ${USERNAME}
RUN nrfutil install "${NRFUTIL_DEVICE}" "${NRFUTIL_BLE_SNIFFER}" \
 && nrfutil device --help >/dev/null \
 && nrfutil ble-sniffer --help >/dev/null

# Claude Code last, as in the rocm target
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS android

# Android app development. JDK 17 (what the current Android Gradle Plugin needs),
# the SDK command-line tools with one platform, build tools and platform-tools
# (adb), and Gradle. The SDK and Gradle live in the user's home, so sdkmanager
# can add platforms without root. Phones aren't reachable over USB here (no
# device passthrough for them), so use wireless debugging: adb pair / adb connect
# to the phone's IP:port.
ARG USERNAME=agent
ARG ANDROID_CMDLINE_TOOLS=15859902
ARG ANDROID_PLATFORM=android-35
ARG ANDROID_BUILD_TOOLS=35.0.0
ARG GRADLE_VERSION=8.14.6
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends openjdk-17-jdk-headless \
 && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    ANDROID_HOME=${HOME}/android-sdk \
    ANDROID_SDK_ROOT=${HOME}/android-sdk \
    GRADLE_HOME=${HOME}/gradle-${GRADLE_VERSION}
ENV PATH=${GRADLE_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}

RUN set -eux; \
    mkdir -p "${ANDROID_HOME}/cmdline-tools"; \
    curl -fsSL -o "${HOME}/cmdline-tools.zip" \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip"; \
    unzip -q "${HOME}/cmdline-tools.zip" -d "${ANDROID_HOME}/cmdline-tools"; \
    mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"; \
    rm "${HOME}/cmdline-tools.zip"

RUN yes | sdkmanager --licenses >/dev/null \
 && sdkmanager "platform-tools" "platforms;${ANDROID_PLATFORM}" "build-tools;${ANDROID_BUILD_TOOLS}" \
 && adb version

RUN curl -fsSL -o "${HOME}/gradle.zip" \
      "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
 && unzip -q "${HOME}/gradle.zip" -d "${HOME}" \
 && rm "${HOME}/gradle.zip" \
 && gradle --version

# Claude Code last, as in the other targets.
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

WORKDIR ${HOME}/work
