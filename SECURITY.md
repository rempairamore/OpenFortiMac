# Security

## Reporting a vulnerability

Please do not open a public issue. Use **[Report a vulnerability](https://github.com/rempairamore/OpenFortiMac/security/advisories/new)** in the repository's Security tab: the report stays private until a fix is out.

Include the OpenFortiMac version (it is at the bottom of the panel), your macOS version and the steps to reproduce. This is a one-person project, so an answer can take a few days.

## Supported versions

Only the [latest release](https://github.com/rempairamore/OpenFortiMac/releases/latest) gets fixes.

## What is in scope

- The app itself: how it stores and passes passwords, the sudo rule it installs in `/etc/sudoers.d/openfortimac`, how it reads `config.json`, the update notice
- The release workflow and the Homebrew cask in [homebrew-tap](https://github.com/rempairamore/homebrew-tap)

Problems in openfortivpn belong to [its own project](https://github.com/adrienverge/openfortivpn/security).

## Known trade-off

The sudo rule lets any process running as your user start openfortivpn as root without a password. It is described in the [README](README.md#allow-openfortivpn-to-run-as-root) and is not a vulnerability report by itself; ideas to narrow it are welcome.

## Checking a release

Releases are built by GitHub Actions and can be verified before installing: see [Verify your download](README.md#verify-your-download).
