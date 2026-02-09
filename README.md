# OpenFortiMac
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)

A native macOS menu bar app for managing [OpenFortiVPN](https://github.com/adrienverge/openfortivpn) connections. Built with Swift and SwiftUI, it sits in your menu bar and lets you connect/disconnect with a single click.

Passwords are stored in the macOS Keychain.

![Main](/img/screen_01.png)
![Settings](/img/screen_02.png)


## Installation

### 1. Install openfortivpn

```bash
brew install openfortivpn
```

### 2. Configure sudoers

openfortivpn needs root privileges to create a VPN tunnel. To avoid password prompts, allow it via sudoers:

```bash
sudo visudo -f /etc/sudoers.d/openfortivpn
```

Add this line (replace `YOUR_USERNAME` with your macOS username):

```
YOUR_USERNAME ALL = NOPASSWD: /opt/homebrew/bin/openfortivpn
```

> Usually the path is `/usr/local/bin/openfortivpn`. Run `which openfortivpn` to check.

### 3. Install the app

#### DMG version

Download the latest `.dmg` from [Releases](../../releases), open it, and drag **OpenFortiMac** to your Applications folder.

#### Build yourself

To build from source instead (Xcode required):

```bash
git clone https://github.com/YOUR_USERNAME/OpenFortiMac.git
cd OpenFortiMac
chmod +x build_dmg.sh
./build_dmg.sh
```

### 4. Launch and configure

Open **OpenFortiMac** from Applications. A lock icon will appear in the menu bar. Click it → **Settings** → **Servers** tab → add your VPN servers.

## Usage

Click the menu bar icon to see your servers. Click a server name to connect. Click **Disconnect** to drop the connection.

| Icon | Status |
|------|--------|
| 🔓 | Disconnected |
| 🔄 | Connecting / Disconnecting |
| 🔒 (green) | Connected |

The app sends native macOS notifications on connect, disconnect, and errors.

## Configuration

Server profiles are stored at `~/Library/Application Support/OpenFortiMac/config.json`. You can edit them through the Settings GUI or manually:

```json
{
    "servers": [
        {
            "id": "office-1",
            "name": "Office VPN",
            "host": "vpn.company.com",
            "port": 443,
            "username": "john.doe"
        }
    ],
    "openfortivpn_path": "/opt/homebrew/bin/openfortivpn"
}
```

Passwords are **not** stored in this file — they live in the macOS Keychain.

The `trusted_cert` field is optional. If omitted, the app uses `--trusted-cert=any`.

## Troubleshooting

**"openfortivpn not found"** — Check the binary path in Settings → General. Run `which openfortivpn` to find yours.

**"sudo: a password is required"** — The sudoers entry is missing or incorrect. See step 2 above.

**Connection fails** — Open Settings → Log tab for details. 

## Uninstall

1. Quit OpenFortiMac
2. Delete from Applications: `rm -rf /Applications/OpenFortiMac.app`
3. Remove config: `rm -rf ~/Library/Application\ Support/OpenFortiMac`
4. Remove sudoers: `sudo rm /etc/sudoers.d/openfortivpn`
