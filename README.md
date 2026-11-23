# OpenFortiMac
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)

A native macOS menu bar app for managing [OpenFortiVPN](https://github.com/adrienverge/openfortivpn) connections. Built with Swift and SwiftUI, it sits in your menu bar and lets you connect/disconnect with a single click.

- One click to connect; when a connection fails, the panel says why
- Two-factor codes (FortiToken, email, SMS) and single sign-on (SAML)
- Passwords in the macOS Keychain, never in a file
- English and Italian

<img src="docs/assets/openfortimac-panel-demo.gif" width="356" alt="Click the OpenFortiMac menu bar icon, then Connect on a server: the panel shows Connecting and then Connected with the tunnel IP">


## Installation

### Homebrew (recommended)

```bash
brew install --cask rempairamore/tap/openfortimac
```

This installs the app and [openfortivpn](https://formulae.brew.sh/formula/openfortivpn) from the [rempairamore/homebrew-tap](https://github.com/rempairamore/homebrew-tap) tap. Update with `brew upgrade --cask rempairamore/tap/openfortimac`: with the full name Homebrew trusts the cask, while recent versions skip casks from taps you have not trusted.

### DMG

1. Install openfortivpn: `brew install openfortivpn`
2. Download the latest `.dmg` from [Releases](../../releases), open it, and drag **OpenFortiMac** to your Applications folder.

### Build yourself

To build from source instead (Xcode 26 or later required):

```bash
git clone https://github.com/rempairamore/OpenFortiMac.git
cd OpenFortiMac
chmod +x build_dmg.sh
./build_dmg.sh
```

### Verify your download

Releases are built by [GitHub Actions](.github/workflows/release.yml) from the tagged commit, not on a developer machine. Each release lists the DMG's SHA-256 and a VirusTotal report. To check that the DMG you downloaded is exactly the one built from this repository (needs the [GitHub CLI](https://cli.github.com)):

```bash
gh attestation verify OpenFortiMac_v1.3.1.dmg -R rempairamore/OpenFortiMac
```

Homebrew checks the same SHA-256 before installing.

Releases are signed with the self-signed certificate "OpenFortiMac Self-Signed" (SHA-1 `7F:43:4F:39:7A:3D:70:CD:9A:0E:9F:74:C0:5D:30:E8:08:04:F1:AA`). It is not an Apple certificate, so Gatekeeper still asks you to confirm the first launch, but it keeps the app's identity stable: macOS does not ask for Keychain access again after updates. Check it with `codesign -dvv /Applications/OpenFortiMac.app`.

### First launch

OpenFortiMac is not notarized by Apple, so macOS blocks it the first time. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the OpenFortiMac message. This is needed only once.

### Allow openfortivpn to run as root

openfortivpn needs root privileges to create the VPN tunnel. On first launch OpenFortiMac opens **Settings → Permission**: click **Set Up…** and enter your administrator password once.

The app installs this rule in `/etc/sudoers.d/openfortimac` (validated with `visudo`, owned by root, read-only):

```
YOUR_USERNAME ALL = (root) NOPASSWD: /opt/homebrew/bin/openfortivpn
```

Click **Remove** in the same place to delete it.

> **Security note:** with this rule any process running as your user can start openfortivpn as root without a password, and `/opt/homebrew` is writable by your user. This is the usual trade-off for openfortivpn GUIs; remove the rule if you stop using the app.

<details>
<summary>Manual setup</summary>

```bash
sudo visudo -f /etc/sudoers.d/openfortimac
```

Add this line (replace `YOUR_USERNAME` with your macOS username):

```
YOUR_USERNAME ALL = (root) NOPASSWD: /opt/homebrew/bin/openfortivpn
```

The path is `/opt/homebrew/bin/openfortivpn` on Apple Silicon and `/usr/local/bin/openfortivpn` on Intel Macs. Run `which openfortivpn` to check.
</details>

### Configure

A lock icon appears in the menu bar. Click it → **Settings** → **Servers** tab → add your VPN servers.

## Usage

Click the menu bar icon to open the panel:

- **Status card** — the current server and connection time, with **Disconnect** (⌘D). While connected it shows the tunnel's IP address, the data received and sent, and the gateway. When a connection fails, the reason stays here with **Show log** and **Edit server**
- **Servers** — hover a server and click **Connect**; a server without a saved password opens its editor
- **Footer** — add a server, Settings (⌘,), Log, the version number, Quit (⌘Q)

Banners at the top of the panel tell you when something needs attention: the administrator permission is missing, a newer release is out, `config.json` has a problem, or a VPN is still running from an earlier session (after a crash or a forced quit), with **Stop it** to close it. Right-click the menu bar icon for a quick menu with Disconnect, Settings and Quit.

### Two-factor codes

If the gateway asks for a code (FortiToken, email or SMS), the panel shows a field: type the code and press **Send**. Gateways with FortiToken Mobile usually send an approval request to your phone instead; to type the code yourself every time, edit the server and set **Advanced → One-time code** to **Ask when connecting**.

### Single sign-on (SAML)

For gateways that sign you in through your company's login page, edit the server and turn on **Advanced → Single sign-on (SAML)**. On Connect, OpenFortiMac opens the gateway's sign-in page in your browser and connects when you are done; no username or password is saved for that server. It needs openfortivpn 1.23 or later and port 8020 free on your Mac, where openfortivpn waits for the browser.

### Self-signed gateways

When a gateway's certificate is not signed by a trusted authority, openfortivpn refuses it. The panel then shows who the certificate belongs to and its sha256 fingerprint, with **Trust this certificate…**: confirm only if the fingerprint is the one your administrator gave you. It is saved in the server's **Advanced → Certificate** field.

Quitting OpenFortiMac disconnects first, also on logout and when Homebrew quits the app to update it, so openfortivpn restores your routes and DNS.

Each server can have its own icon, chosen in the server editor.

| Icon | Status |
|------|--------|
| 🔓 | Disconnected |
| 🔄 (turning) | Connecting / Disconnecting |
| 🔒 (green) | Connected |

The app sends native macOS notifications on connect, disconnect, and errors.

**Settings → Servers** also has **Duplicate** (right-click a server) and, under the **…** button, **Import servers…** and **Export servers…** to move your servers to another Mac. Exported files never contain passwords.

**Settings → General** shows the version and checks for updates: the app asks GitHub for the latest release once a day and tells you when there is a newer one. It downloads nothing by itself, and you can turn the check off there.

**Settings → Log** shows what openfortivpn prints, live, with search and **Save…**.

The app is in English and Italian, following the language of your Mac.

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
            "username": "john.doe",
            "realm": "staff",
            "min_tls": "1.2",
            "one_time_code": "ask"
        },
        {
            "id": "customer-1",
            "name": "Customer",
            "host": "ssl.customer.example",
            "port": 443,
            "single_sign_on": true
        }
    ],
    "openfortivpn_path": "/opt/homebrew/bin/openfortivpn"
}
```

Passwords are **not** stored in this file — they live in the macOS Keychain. A `"password"` you add by hand is moved to the Keychain and removed from the file the next time the app starts.

Only `name`, `host` and `username` are required (`username` is not needed with `single_sign_on`). `port` defaults to 443. `id` is what ties a server to its password in the Keychain: leave it out in a server you write by hand and the app adds one. The other keys are optional and match the **Advanced** section of the server editor:

| Key | In the editor | Meaning |
|-----|---------------|---------|
| `trusted_cert` | Certificate | sha256 digest of a self-signed gateway's certificate (see [Self-signed gateways](#self-signed-gateways)) |
| `realm` | Realm | Only if your FortiGate uses authentication realms: the web portal address then ends with the realm name, for example `https://vpn.company.com/staff` |
| `one_time_code` | One-time code | `"ask"` to always type the two-factor code instead of approving on the phone |
| `min_tls` | Minimum TLS | `"1.0"`, `"1.1"`, `"1.2"` or `"1.3"`, for old gateways that need less than the system default |
| `single_sign_on` | Single sign-on (SAML) | `true` to sign in through the browser |

If the file has a mistake, nothing is lost: a server with a problem is left out and the others load, and before changing anything the app keeps a copy of your file next to it as `config.backup-….json`. A notice in the panel and in Settings takes you to it.

## Troubleshooting

**"openfortivpn not found"** — Check the binary path in Settings → General. Run `which openfortivpn` to find yours.

**"Administrator permission not set up"** — The sudo rule is missing or points to another openfortivpn path. Open Settings → Permission and click **Set Up…** (or **Update…**).

**"OpenFortiMac is damaged" / "cannot be opened"** — See [First launch](#first-launch).

**Login works in the browser at `https://…/something` but not in the app** — Your gateway uses an authentication realm: edit the server and put `something` in **Advanced → Realm**.

**"Two-factor code missing"** — The gateway wanted a code and got none. Connect again and type it in the panel; if the field never appears, set **Advanced → One-time code** to **Ask when connecting**.

**"A VPN is still running"** — openfortivpn survived a crash or a forced quit of the app. Click **Stop it** in the panel; your routes and DNS go back to normal.

**"Some servers were left out" / "config.json could not be read"** — See the end of [Configuration](#configuration).

**Connection fails** — The panel shows the reason; **Show log** opens Settings → Log with the details.

## Uninstall

### Homebrew

```bash
brew uninstall --zap --cask rempairamore/tap/openfortimac
```

`--zap` also removes the sudo rule `/etc/sudoers.d/openfortimac` (brew asks for your password), the configuration and the preferences. Without `--zap` both stay: Homebrew runs the same uninstall steps when it updates the app, so the rule is kept there on purpose. To keep your servers but drop the rule, use Settings → Permission → **Remove** before `brew uninstall --cask rempairamore/tap/openfortimac`.

### Manual

1. Settings → Permission → **Remove**
2. Quit OpenFortiMac
3. Delete from Applications: `rm -rf /Applications/OpenFortiMac.app`
4. Remove config: `rm -rf ~/Library/Application\ Support/OpenFortiMac`
5. Remove preferences: `defaults delete rempairamore.OpenFortiMac`

Deleting a server in Settings also deletes its password from the Keychain. If you removed the app without doing that, the passwords are the `com.openfortimac.vpn` items in **Keychain Access**.

If you followed the manual setup of older versions, also run `sudo rm /etc/sudoers.d/openfortivpn`.

## Releasing

1. Bump `MARKETING_VERSION` in Xcode and add a `## vX.Y.Z` section to `CHANGELOG.md`.
2. Merge to `main`. That's it.

When `main` gets a version that has no tag yet, the [Release workflow](.github/workflows/release.yml) builds a universal DMG, attests its provenance, scans it on VirusTotal, publishes the GitHub release (creating the `vX.Y.Z` tag) and updates [homebrew-tap](https://github.com/rempairamore/homebrew-tap) through a pull request that it merges itself once `brew style` and `brew audit` pass. Homebrew users get it with `brew upgrade --cask rempairamore/tap/openfortimac`.

To try a build without shipping it, push a tag with a suffix (for example `v1.3.2-rc.1`): it creates a pre-release and skips Homebrew. The workflow needs these repository secrets:

- `SIGNING_CERT_P12` (base64 of the certificate's `.p12`) and `SIGNING_CERT_PASSWORD`: releases fail without them, and the workflow checks the app is signed with the certificate whose SHA-1 is in `EXPECTED_CERT_SHA1`
- `VIRUSTOTAL_API_KEY`
- `HOMEBREW_TAP_TOKEN`: fine-grained token with *Contents* and *Pull requests* write access to `homebrew-tap` only

Local builds use the certificate when it is in your keychain and fall back to an ad-hoc signature otherwise.

The demo GIF at the top of this README is generated with `python3 scripts/make_panel_demo.py` (macOS and ffmpeg required) from example data.
