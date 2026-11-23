# Changelog

## v1.4.2

### Changed
- All passwords are in one Keychain item ("OpenFortiMac passwords") instead of one per server, so after an update macOS asks for Keychain access once, not once per server. Passwords saved by earlier versions are moved the first time each server is used, which asks for the old items one last time. Choose **Always Allow**
- The note of 1.3.2 was wrong: the stable certificate does not stop macOS from asking after an update. Without an Apple developer team the permission is tied to the exact build
- Menu bar icon: a shield instead of the lock. Dimmed when disconnected, filling up and emptying while connecting, green with a check when connected
- Settings: the tabs are an icon bar, like the preferences of macOS. The band that the system tabs drew across the window is gone
- New app icon: the green shield with the check on a dark tile, at the standard size of macOS icons (the old one filled its square and looked larger than the others)

## v1.4.1

### Added
- **Theme** in Settings → General: Light, Dark or Dracula. The app starts in Dark and no longer follows the appearance of the Mac
- **Language** in Settings → General: English or Italian, applied when the app restarts

### Changed
- The app is in English on every Mac again. 1.4.0 followed the language of the Mac, so it turned Italian where that is the system language
- A larger field for the two-factor code, the Log in its own box, and one background with larger buttons in the server editor

## v1.4.0

### Added
- **Two-factor codes**: when the gateway asks for a code (FortiToken, email or SMS), the panel shows a field to type it. **One-time code → Ask when connecting**, in the server's Advanced options, skips the FortiToken push and always asks for the code
- **Single sign-on (SAML)**: with the option on, OpenFortiMac opens the gateway's sign-in page in your browser and connects when the sign-in is done. No username or password is saved for these servers. Needs openfortivpn 1.23 or later
- **Trust this certificate…**: when a gateway's certificate is not signed by a trusted authority, the panel shows who it belongs to and its sha256 fingerprint, and saves it for that server if you confirm. No more copying the digest from the Log
- The reason of a failed connection stays in the panel, with **Show log** and **Edit server**
- While connected, the panel shows the tunnel's IP address, the data received and sent, and the gateway
- A VPN left running by an earlier session (after a crash or a forced quit) is found at launch: the panel offers **Stop it**
- Update notice: the panel and Settings → General tell you when a newer release is out. The app asks GitHub once a day and downloads nothing by itself; turn it off in Settings → General
- The version number, at the bottom of the panel and in Settings → General
- Server editor: an **Advanced** section with Certificate, Realm, One-time code, **Minimum TLS** and Single sign-on
- **Import servers…**, **Export servers…** and **Duplicate** in Settings → Servers. Exported files never contain passwords
- Log: time and level on each line, colours for warnings and errors, search and **Save…**. It updates while the window is open
- Italian translation

### Changed
- The menu bar icon turns while connecting and disconnecting
- The Settings window no longer stays above every other window
- No more emoji in notifications and Settings
- The server editor no longer reads the saved password: the field is empty and the saved password is kept unless you type a new one. The panel checks whether a password exists without reading it

### Fixed
- An error in `config.json` (a port written as text, a server without a username, a missing comma) made every server disappear, and the next change overwrote the file. Now a server with a problem is left out and the others load, a port written as text is accepted, a server without an `id` gets one, and a copy of the original file is kept next to it as `config.backup-….json`, with a notice in the panel and in Settings
- Opening Settings rewrote `config.json` every time
- A `"password"` written by hand in `config.json` was ignored and stayed on disk in clear text: it is now moved to the Keychain and removed from the file
- Temporary configuration files left by a crashed session are removed at launch

## v1.3.4

### Fixed
- Quitting now disconnects first and waits for openfortivpn to restore routes and DNS (up to 6 seconds), from every quit path: the menu, logout, Homebrew's quit during `brew upgrade` and `brew uninstall`, and SIGTERM. Before, openfortivpn could stay up as root with no app left to stop it
- The permission check reported the sudo rule as set up for administrators who have any other passwordless sudo rule; it now really runs `openfortivpn --version` through `sudo -n`
- The temporary openfortivpn configuration, which contains the password, is deleted as soon as openfortivpn has read it, instead of when the connection ends
- Opening another server from the panel while the server editor was open saved the first server's fields, password included, into the second one
- Cancelling while the permission is being checked no longer starts openfortivpn afterwards
- Homebrew updates no longer remove the sudo rule: the cask removes `/etc/sudoers.d/openfortimac` only on `brew uninstall --zap`. Installs made with an earlier cask still remove it on their next update, one last time: click **Set Up…** in Settings → Permission again.

### Changed
- No more `--trusted-cert=any`: it never disabled the certificate check, it did nothing. The certificate error now points to the sha256 digest in the Log

The permission check, server editor, temporary configuration and quitting issues were found by [@RomanVassilchenko](https://github.com/RomanVassilchenko) in [#12](https://github.com/rempairamore/OpenFortiMac/pull/12).

## v1.3.3

### Added
- **Realm (optional)** in the server editor, passed to openfortivpn as `realm` for gateways that use authentication realms. A `"realm"` key added by hand to `config.json` is now kept ([#11](https://github.com/rempairamore/OpenFortiMac/issues/11))

### Changed
- Server values containing a line break are rejected before they reach openfortivpn's configuration file
- Taller server editor, so the new field and the icons fit

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