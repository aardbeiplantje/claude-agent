## BLE sniffer (nRF52840 sniffer dongle)

- Tool: `nrfutil ble-sniffer`, installed at latest. After starting `sniff`, check the dongle firmware version in `~/.nrfutil/logs/nrfutil-ble-sniffer.log`.
- Port: the dongle exposes more than one serial port (`/dev/ttyACM*`). If a port times out on writes, try the other one.
- Start the sniffer in the background before a test, and kill it by PID afterwards. Never kill by name: `pkill -f` matches the calling shell itself.
  - Command: `nrfutil ble-sniffer sniff --port <port> --output-pcap-file <pcap> &`
  - Put `<pcap>` in the scratchpad and kill with `kill <pid>`.
- Captures and logs go in the scratchpad, never in the repository.
- Inspect a capture with `tshark -r <pcap> -Y btatt`.
- If the dongle stops answering: put it into DFU mode (bootloader), flash the bundled firmware with `nrfutil device program --traits nordicDfu --firmware <zip>`, then replug it.

## Git branches

- Do not create, switch or work on branches unless the user asks for one. Commit to the branch that is checked out.
