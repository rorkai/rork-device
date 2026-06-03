# Roadmap

`rork-device` is a modern Swift implementation of iOS device communication
protocols. The project grows by production-grade vertical slices: each release
should expose useful public APIs, matching CLI commands, protocol tests, and
clear limitations.

## 0.1.0: Device Sessions And App Installation

The first release focuses on the app-install workflows used by developer tools:

- Parse existing pairing records.
- Connect through local `usbmuxd` or a direct Lockdown endpoint.
- Query basic device information through Lockdown.
- Start Lockdown services.
- Upload IPA files or in-memory IPA bytes through AFC staging.
- Install, remove, and copy provisioning profiles through MISAgent.
- List, install, and uninstall applications through InstallationProxy.
- Expose structured progress and errors.
- Upgrade secure Lockdown and service connections on Apple platforms.
- Provide a Swift library and `rorkdevice` CLI.
- Include an opt-in physical-device smoke test for list, info, profile
  install, IPA install, and IPA uninstall.

Out of scope for 0.1.0:

- Creating new pairings or driving the trust dialog.
- Device add/remove event streams.
- Wi-Fi sync discovery.
- Developer disk image mounting.
- Debugserver, syslog, crash reports, screenshots, backup, and restore.
- Windows support.

Secure-session upgrades are represented by the public `SecureSessionUpgrader`
protocol. The Apple backend is built in for 0.1.0, and additional platform
backends can be added without changing the high-level install flow.

## 0.2.0: Device Events And File Access

The second release expands beyond the app-install vertical slice:

- Stream device attach and detach events through usbmux.
- Expose high-level file operations on AFC.
- Vend application Documents and containers through HouseArrest.
- Add CLI commands for watching devices and moving files.
- Keep pairing creation as the next trust-flow milestone so certificate
  generation, trust prompts, persistence, and physical-device validation can be
  designed together.

## Future Milestones

The next milestones should expand service coverage without weakening the public
API boundaries:

- Pairing creation, validation, unpairing, and pairing-record storage.
- Richer usbmuxd discovery and Wi-Fi sync discovery.
- Syslog relay and crash report retrieval.
- Developer image mounting, screenshots, and debugserver proxying.
- Backup, restore, diagnostics, and recovery services.

## Compatibility Strategy

Compatibility is validated with protocol fixtures, fake service peers, and
opt-in physical-device checks while keeping the implementation Swift-first and
independently structured.
