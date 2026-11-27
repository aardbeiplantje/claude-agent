# The final targets share one "base" stage. bash, dev, arduino and web build for
# linux/amd64 and linux/arm64 (TARGETARCH); rocm and android are amd64 only, and
# hailo is arm64 only (Raspberry Pi 5).
#
#   rocm     ROCm dev image + Rust (rustup) + Python venv (torch from TheRock) + Claude Code
#            (BASE_IMAGE=rocm/dev-ubuntu-24.04)
#   bash     basic: the general dev tools in base + Claude Code (BASE_IMAGE=ubuntu:24.04)
#   dev      full dev: base + Rust (rustup), Node.js, Go, rtl-sdr + Claude Code
#            (BASE_IMAGE=ubuntu:24.04)
#   arduino  Ubuntu + arduino-cli + ESP32 core + usb_logger (USB power meters)
#            + Claude Code (BASE_IMAGE=ubuntu:24.04)
#   android  Ubuntu + JDK 17 + Android SDK (platform, build-tools, platform-tools)
#            + Gradle + Claude Code (BASE_IMAGE=ubuntu:24.04)
#   web      Ubuntu + Node.js (LTS) + Playwright with Firefox (for checking web UIs)
#            + Claude Code (BASE_IMAGE=ubuntu:24.04)
#   hailo    Raspberry Pi 5 only: Debian bookworm + HailoRT/hailortcli + TAPPAS
#            (GStreamer hailonet/hailofilter) + libcamera + Claude Code
#            (BASE_IMAGE=debian:bookworm-slim)
#
# docker-bake.hcl sets BASE_IMAGE per target; "docker buildx bake" builds all.

ARG BASE_IMAGE=ubuntu:24.04

# --------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base

USER root
ENV DEBIAN_FRONTEND=noninteractive

# The Ubuntu base image drops man pages and docs (dpkg excludes); remove that so
# man, perldoc and the packages below keep their documentation.
RUN rm -f /etc/dpkg/dpkg.cfg.d/excludes \
 && apt-get update \
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
        cpanminus perl-doc libperl-dev perltidy \
        libdbi-perl libdbd-sqlite3-perl libtext-csv-perl libyaml-libyaml-perl \
        libmoose-perl libreadonly-perl \
        time man-db manpages tmux vim-tiny gawk psmisc moreutils bc ncdu \
        entr direnv \
 && { apt-cache show ltrace >/dev/null 2>&1 \
        && apt-get install -y --no-install-recommends ltrace \
        || echo "ltrace is not in this release (bookworm): skipped" >&2; } \
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
# Same as in the dev target.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile default --default-toolchain stable \
 && "${HOME}/.cargo/bin/cargo" --version
ENV PATH=${HOME}/.cargo/bin:${PATH}

# Python venv for the agent user with torch and the Hugging Face / data tools.
# torch, torchvision and torchaudio are the ROCm wheels that go with TheRock
# (AMD's ROCm build), taken from TheRock's nightly index for one GPU family
# (TORCH_INDEX; gfx1151 by default). The versions are one matching nightly set
# (torch 2.9.1 with torchvision 0.24 and torchaudio 2.9). The other packages are
# pinned. numpy stays 1.26.x, since pyarrow 17 does not work with NumPy 2.
ARG TORCH_INDEX=https://rocm.nightlies.amd.com/v2/gfx1151/
ARG TORCH_VERSION=2.9.1+rocm7.13.0a20260513
ARG TORCHVISION_VERSION=0.24.0+rocm7.13.0a20260513
ARG TORCHAUDIO_VERSION=2.9.0+rocm7.13.0a20260513
ARG NUMPY_VERSION=1.26.4
ARG PYARROW_VERSION=17.0.0
ARG SOUNDFILE_VERSION=0.14.0
ARG PILLOW_VERSION=13.0.0
ARG TRANSFORMERS_VERSION=5.5.1
# The downloads are large (the torch wheels alone are ~700 MB), so this is split
# into layers and uses a pip cache mount: a failed or timed-out download resumes
# from the wheels already fetched, and finished layers stay cached. Needs the
# BuildKit builder (the default for docker buildx bake).
ARG USERNAME=agent
ARG UID=1000
ARG GID=1000
RUN python3 -m venv "${HOME}/venv" \
 && "${HOME}/venv/bin/pip" --version
ENV PATH=${HOME}/venv/bin:${PATH} \
    PIP_RETRIES=10 \
    PIP_TIMEOUT=300
# ROCm builds only: any later pip install that asks for torch or triton gets
# the constraint versions above, never PyPI's CUDA builds (see the file).
COPY config/pip-constraints-rocm.txt /etc/pip-constraints-rocm.txt
ENV PIP_CONSTRAINT=/etc/pip-constraints-rocm.txt
# torch, torchvision, torchaudio and numpy (torch's own deps come from the same index)
RUN --mount=type=cache,target=/var/cache/pip-rocm,uid=${UID},gid=${GID} \
    PIP_CACHE_DIR=/var/cache/pip-rocm \
 && pip install --extra-index-url "${TORCH_INDEX}" \
        "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}" "numpy==${NUMPY_VERSION}"
# The rest, from PyPI
RUN --mount=type=cache,target=/var/cache/pip-rocm,uid=${UID},gid=${GID} \
    PIP_CACHE_DIR=/var/cache/pip-rocm \
 && pip install "numpy==${NUMPY_VERSION}" "pyarrow==${PYARROW_VERSION}" \
        "soundfile==${SOUNDFILE_VERSION}" "pillow==${PILLOW_VERSION}" \
        "transformers==${TRANSFORMERS_VERSION}"
# Diffusion, training and notebook helpers, from PyPI. Pins are the latest that
# work with torch 2.9.1, transformers 5.5.1 and numpy 1.26: huggingface_hub must
# be 1.32 or newer for diffusers, and 2.x is out of range for transformers.
# datasets is not in here: 5.x needs pyarrow 24, and pyarrow stays at 17.
ARG HUGGINGFACE_HUB_VERSION=1.33.0
ARG SAFETENSORS_VERSION=0.8.0
ARG DIFFUSERS_VERSION=0.43.0
ARG ACCELERATE_VERSION=1.16.0
ARG MATPLOTLIB_VERSION=3.11.2
ARG TENSORBOARD_VERSION=2.21.0
ARG KAGGLEHUB_VERSION=1.0.3
ARG PYBIND11_VERSION=3.1.0
RUN --mount=type=cache,target=/var/cache/pip-rocm,uid=${UID},gid=${GID} \
    PIP_CACHE_DIR=/var/cache/pip-rocm \
 && pip install "huggingface_hub==${HUGGINGFACE_HUB_VERSION}" "safetensors==${SAFETENSORS_VERSION}" \
        "diffusers==${DIFFUSERS_VERSION}" "accelerate==${ACCELERATE_VERSION}" \
        "matplotlib==${MATPLOTLIB_VERSION}" "tensorboard==${TENSORBOARD_VERSION}" \
        "kagglehub==${KAGGLEHUB_VERSION}" "pybind11==${PYBIND11_VERSION}"
# Check that the stack imports (no GPU is needed for that)
RUN python -c "import numpy, pyarrow, soundfile, PIL, transformers, torch, torchvision, torchaudio, diffusers, accelerate, matplotlib, kagglehub; print('torch', torch.__version__, 'hip', torch.version.hip, '| transformers', transformers.__version__, '| diffusers', diffusers.__version__, '| pyarrow', pyarrow.__version__)" \
 && pip check

# Claude Code, installed for the user (lands in ~/.local/bin). Kept last so
# changing CLAUDE_REFRESH ("run.sh --update") only rebuilds this layer.
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

# System-wide Claude Code instructions (managed policy location, under /etc, so
# the ~/.claude volume does not hide them). CLAUDE.md imports AGENTS.md. Copied
# last, so editing them only rebuilds this layer in each image.
COPY config/claude-code/ /etc/claude-code/

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS bash

# Basic: the general dev tools from base (python, perl, lua, C/C++, cmake, ...)
# and Claude Code. Rust, Node.js, Go and rtl-sdr are in the dev target.
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

COPY config/claude-code/ /etc/claude-code/

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS dev

# Full dev image: base + Node.js (+ npm) and Go and rtl-sdr from Ubuntu's apt,
# Rust (rustup), Claude Code.
# ARGs don't carry across stages,
# hence USERNAME again (same default as in base).
ARG USERNAME=agent
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm golang-go \
        rtl-sdr \
        libjson-xs-perl libwww-curl-perl libterm-readline-gnu-perl libdata-uuid-perl \
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

# System-wide Claude Code instructions (managed policy location, under /etc, so
# the ~/.claude volume does not hide them). CLAUDE.md imports AGENTS.md. Copied
# last, so editing them only rebuilds this layer in each image.
COPY config/claude-code/ /etc/claude-code/

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS arduino

ARG ARDUINO_CLI_VERSION=1.5.1
ARG ARDUINO_BOARD_URLS="https://espressif.github.io/arduino-esp32/package_esp32_index.json"
ARG ARDUINO_CORES="esp32:esp32"

# arduino-cli from the official GitHub release (asset name per architecture)
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in amd64) acli_os=Linux_64bit ;; arm64) acli_os=Linux_ARM64 ;; *) echo "unsupported: ${TARGETARCH}" >&2; exit 1 ;; esac; \
    mkdir -p "${HOME}/.local/bin"; \
    curl -fsSL "https://github.com/arduino/arduino-cli/releases/download/v${ARDUINO_CLI_VERSION}/arduino-cli_${ARDUINO_CLI_VERSION}_${acli_os}.tar.gz" \
      | tar -xz -C "${HOME}/.local/bin" arduino-cli; \
    arduino-cli version

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

# Nordic's nrfutil, installed for the agent user (as on a regular host install)
# in ~/.local/bin, which is on PATH. The launcher is pinned by sha256; it is then
# self-upgraded to the latest release and ble-sniffer is installed at latest.
# device is pinned; device flashes the nRF52840 Dongle's sniffer firmware
# (nrfutil device program --traits nordicDfu --firmware <zip>), and ble-sniffer
# reads the sniffer's serial output (nrfutil ble-sniffer sniff --port ...).
ARG NRFUTIL_URL="https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/x86_64-unknown-linux-gnu/nrfutil-x86_64-unknown-linux-gnu-1.4.2-8a9090a"
ARG NRFUTIL_SHA256=a14996288928a92081cadeefd2dd37fcb54ee99a568fd4eaa6fb9586a51fba57
ARG NRFUTIL_URL_ARM64="https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/aarch64-unknown-linux-gnu/nrfutil-aarch64-unknown-linux-gnu-1.4.2-8a9090a"
ARG NRFUTIL_SHA256_ARM64=4850783fb494b9ef27a18347fad5376ad8c5506f93cb0da1e3908f9011672664
ARG NRFUTIL_DEVICE=device=2.17.5
# Changing NRFUTIL_REFRESH ("run.sh --update") re-runs self-upgrade and the
# latest ble-sniffer install; otherwise this layer stays cached.
ARG NRFUTIL_REFRESH=0
RUN echo "nrfutil refresh: ${NRFUTIL_REFRESH}" \
 && mkdir -p "${HOME}/.local/bin" \
 && if [ "${TARGETARCH}" = arm64 ]; then nrf_url="${NRFUTIL_URL_ARM64}"; nrf_sha="${NRFUTIL_SHA256_ARM64}"; \
    else nrf_url="${NRFUTIL_URL}"; nrf_sha="${NRFUTIL_SHA256}"; fi \
 && curl -fsSL -o "${HOME}/.local/bin/nrfutil" "${nrf_url}" \
 && echo "${nrf_sha}  ${HOME}/.local/bin/nrfutil" | sha256sum -c - \
 && chmod 0755 "${HOME}/.local/bin/nrfutil" \
 && nrfutil self-upgrade \
 && nrfutil install "${NRFUTIL_DEVICE}" \
 && nrfutil install ble-sniffer --force \
 && nrfutil device --help >/dev/null \
 && nrfutil ble-sniffer --help >/dev/null

# Claude Code last, as in the rocm target
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

# System-wide Claude Code instructions (managed policy location, under /etc, so
# the ~/.claude volume does not hide them). CLAUDE.md imports AGENTS.md. Copied
# last, so editing them only rebuilds this layer in each image.
COPY config/claude-code/ /etc/claude-code/

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

# System-wide Claude Code instructions (managed policy location, under /etc, so
# the ~/.claude volume does not hide them). CLAUDE.md imports AGENTS.md. Copied
# last, so editing them only rebuilds this layer in each image.
COPY config/claude-code/ /etc/claude-code/

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS hailo

# Raspberry Pi 5 with a Hailo-8 (arm64 only; run.sh refuses other hosts). Built on
# Debian bookworm, the release Raspberry Pi OS is based on: the Hailo packages come
# from the Raspberry Pi apt repository for bookworm, and its HailoRT Python bindings
# are for bookworm's python3 (3.11). The driver stays on the host (hailo-all, dkms);
# the container gets /dev/hailo0 through run.sh. Contents: hailortcli, the HailoRT
# Python package, GStreamer with the TAPPAS elements (hailonet, hailofilter,
# hailooverlay), libcamera and the Python GStreamer/OpenCV/numpy bindings.
ARG USERNAME=agent
ARG CLAUDE_REFRESH=0
ARG TARGETARCH
USER root
RUN [ "${TARGETARCH}" = arm64 ] || { echo "hailo: arm64 (Raspberry Pi 5) only" >&2; exit 1; }

# The Raspberry Pi apt repository, signed (same as the Pi's own sources)
RUN apt-get update \
 && apt-get install -y --no-install-recommends gnupg \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://archive.raspberrypi.com/debian/raspberrypi.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/raspberrypi-archive-keyring.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.com/debian/ bookworm main" \
        > /etc/apt/sources.list.d/raspi.list \
 && apt-get update

# HailoRT and TAPPAS core, pinned as in the hailo-yolo Dockerfile (hailo-raspi stage)
ADD https://archive.raspberrypi.com/debian/pool/main/h/hailort/hailort_4.23.0_arm64.deb /tmp/hailort_4.23.0_arm64.deb
ADD https://archive.raspberrypi.com/debian/pool/main/h/hailo-tappas-core/hailo-tappas-core_3.31.0-1_arm64.deb /tmp/hailo-tappas-core_3.31.0-1_arm64.deb
RUN apt-get install -y --no-install-recommends \
        hailo-all python3-hailort /tmp/*.deb \
        gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-plugins-rtp \
        gstreamer1.0-libav gstreamer1.0-libcamera gir1.2-gstreamer-1.0 \
        libgstreamer-opencv1.0-0 python3-gi python3-numpy python3-opencv \
        python3-protobuf v4l-utils \
 && rm -f /tmp/*.deb \
 && rm -rf /var/lib/apt/lists/* \
 && hailortcli --version

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Claude Code, as in the bash target
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

COPY config/claude-code/ /etc/claude-code/

WORKDIR ${HOME}/work

# --------------------------------------------------------------------------
FROM base AS web

# Front-end work, with a browser so Claude can look at the page it builds.
# Node.js LTS from the official tarball (Ubuntu's nodejs is too old for current
# tooling), Playwright, and Firefox only (Playwright's own build, no Chromium
# or WebKit). The browser sits in /opt so it doesn't live in the ~/.claude
# volume and is readable by the agent user.
ARG USERNAME=agent
ARG NODE_VERSION=22.11.0
ARG PLAYWRIGHT_VERSION=1.56.1
USER root
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    NODE_PATH=/usr/local/lib/node_modules

# Fonts for screenshots: without them emoji and some scripts are boxes, and
# Arial/Helvetica metrics differ.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        fonts-noto-core fonts-noto-color-emoji fonts-liberation \
 && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
# Node.js (npm included) into /usr/local, checked against the sha256 list that
# nodejs.org publishes for this version. One tarball per architecture.
RUN set -eux; \
    cd /tmp; \
    case "${TARGETARCH}" in amd64) node_arch=x64 ;; arm64) node_arch=arm64 ;; *) echo "unsupported: ${TARGETARCH}" >&2; exit 1 ;; esac; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSLO "${base}/${tarball}"; \
    curl -fsSLO "${base}/SHASUMS256.txt"; \
    grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "${tarball}" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "${tarball}" SHASUMS256.txt; \
    node --version; npm --version

# Playwright and its Firefox build. --with-deps installs the shared libraries
# Firefox needs (as root here, so no sudo). Only Firefox is installed.
RUN npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
 && playwright install --with-deps firefox \
 && chmod -R a+rX /opt/ms-playwright \
 && rm -rf /var/lib/apt/lists/* /root/.npm /tmp/* \
 && playwright --version

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Same user setup as the other targets: Claude Code last, so a CLAUDE_REFRESH
# change only rebuilds this layer.
ENV HOME=/home/${USERNAME} \
    PATH=/home/${USERNAME}/.local/bin:${PATH} \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude
ARG CLAUDE_REFRESH=0
RUN echo "claude refresh: ${CLAUDE_REFRESH}" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

# System-wide Claude Code instructions (managed policy location, under /etc, so
# the ~/.claude volume does not hide them). CLAUDE.md imports AGENTS.md.
COPY config/claude-code/ /etc/claude-code/

WORKDIR ${HOME}/work
