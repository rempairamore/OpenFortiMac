# Changelog

## Unreleased

### Added
- Multiple simultaneous connections (Settings → General, off by default): one openfortivpn process, status card, log and Disconnect per server
- Per-server options: "Don't change routes or DNS" (`--no-routes --no-dns`), static routes through the tunnel's ppp interface, connect at launch
- Per-server auto-reconnect: retries with backoff when a tunnel drops, waits for the network while offline, stops on authentication or certificate errors
- Sudo rule can also allow `/sbin/route` for ppp interfaces, only when a server uses static routes
- `openfortimac` command line tool (the app executable): list, status, connect, disconnect, logs, add, edit, remove, show, settings, permission
- Log file at `~/Library/Logs/OpenFortiMac/openfortimac.log`
- Right-click menu: connect any idle server
- Optional monochrome menu bar icon (Settings → General → Menu bar icon): a template shield that shows the number of connected tunnels; the classic lock stays the default

### Changed
- Quitting disconnects all tunnels first, whatever the way of quitting (menu, `brew uninstall`, logout, SIGTERM)
- The temporary openfortivpn config (with the password) is deleted as soon as the tunnel is up

### Fixed
- Permission check: `sudo -l` also lists commands that still need a password for administrators; the check now runs `openfortivpn --version` through `sudo -n`

## v1.3.2

### Changed
- Releases are signed with a stable self-signed certificate ("OpenFortiMac Self-Signed"), so macOS keeps the app's Keychain access across updates instead of asking again after each one. Updating to 1.3.2 asks one last time: choose **Always Allow**.

## v1.3.1

### Added
- Releases are built by GitHub Actions with signed build provenance (`gh attestation verify`) and a VirusTotal report

### Fixed
- Universal binary: the app now runs on Intel Macs too (1.3.0 was Apple Silicon only)

## v1.3.0

### Added
- New menu bar panel: status card with connection time, tunnel IP and Disconnect, server list with Connect on hover, quick actions footer
- Right-click on the menu bar icon opens a quick menu (Disconnect, Settings, Quit)
- Server icons, chosen in the server editor
- Homebrew install: `brew install --cask rempairamore/tap/openfortimac`
- Settings → Permission: set up, update or remove the openfortivpn sudo rule with one password prompt
- Panel banner when the sudo rule or openfortivpn is missing
- First launch opens the permission setup when needed

### Changed
- Servers in Settings are shown as cards with icon, address and a missing-password badge
- A server without a saved password opens its editor instead of an alert
- `build_dmg.sh` names the DMG after the version and prints the values for the Homebrew cask
- Connecting without a sudo rule now fails immediately with a clear message

### Fixed
- Disconnect no longer runs `sudo kill` / `sudo pkill`, which the sudo rule never allowed; openfortivpn is stopped through its sudo parent

## v1.2.0

### Added
- Colored status dot in the menu bar (green when connected, orange when connecting)
- Server names are greyed out in the menu bar while connected
- Double-click a server profile to edit it
- Trash icon on each server row with delete confirmation dialog

### Fixed
- Server list now refreshes immediately after editing or adding a profile

## v1.1.0

- Initial release
- Native macOS menu bar app for OpenFortiVPN
- Multiple VPN server profiles with Keychain password storage
- JSON configuration with GUI editor
- Connection log viewer
- Native macOS notifications
- Launch at Login support
- App icon