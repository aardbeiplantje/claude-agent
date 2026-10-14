FROM rocm/dev-ubuntu-24.04:latest AS base-rocm-dev

USER root

RUN curl -fsSL https://claude.ai/install.sh | bash 

ADD https://downloads.arduino.cc/arduino-cli/arduino-cli_1.5.0-1_amd64.deb /tmp/arduino-cli.deb
RUN dpkg -i /tmp/arduino-cli.deb && rm /tmp/arduino-cli.deb

