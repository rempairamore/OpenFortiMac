# Changelog

## v1.3.0

### Added
- Homebrew install: `brew install --cask rempairamore/tap/openfortimac`
- Settings → General → Administrator Permission: set up, update or remove the openfortivpn sudo rule with one password prompt
- Menu bar warning when the sudo rule or openfortivpn is missing
- First launch opens the permission setup when needed

### Changed
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