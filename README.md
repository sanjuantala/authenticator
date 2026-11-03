# Totem

A private two-factor authenticator for **macOS** and **Chromium browsers** (Chrome, Brave, Edge, Arc).
A menu bar app and a browser extension share one encrypted vault, sync on your Mac, and back up to your own Google Drive. No accounts, no servers.

## Features

- **Codes everywhere**: menu bar app, browser popup, and a Spotlight-style quick search (`⌥⌘2`)
- **One-click fill** on 2FA fields, with anti-phishing: codes fill only on sites you've saved
- **Scan QR codes from your screen**, no phone needed
- **Touch ID**, secured by the Mac's Secure Enclave
- **Import** from Google Authenticator, Aegis, 2FAS, Bitwarden and `otpauth://` links
- **Encrypted backup** to Google Drive, iCloud Drive or any synced folder
- **One-click updates** for both the app and the extension

## Install

Requires macOS 14 or later and Apple's Command Line Tools (full Xcode isn't needed).

```bash
xcode-select --install   # only if you don't have the Command Line Tools yet
curl -fsSL https://raw.githubusercontent.com/sanjuantala/authenticator/main/get.sh | bash
```

This downloads the latest version, builds `Totem.app` into `/Applications` and opens it. Look for the Totem mark in your menu bar.

### Add the browser extension (once)

1. Open `chrome://extensions` and turn on **Developer mode**.
2. Click **Load unpacked**, press `⌘⇧G`, paste `~/Totem/source/extension` and choose it.
3. In Totem for Mac: **Settings → Backup & Browser → Connect browsers**.
4. In the extension popup: **Use my Mac's vault with Touch ID**.

## Update

Click **Install update** at the bottom of Totem's menu when it appears. Totem checks GitHub at most once an hour; to check now, use **Settings → General → Check for updates**. The extension reloads itself, so just unlock it once afterwards.

## Back up to Google Drive

1. Install [Google Drive for desktop](https://www.google.com/drive/download/) and sign in.
2. In Totem: **Settings → Backup & Browser → Back up to Google Drive**.

Totem saves an encrypted copy into `My Drive/Totem/`, plus a dated backup each day (the newest 30 are kept). Google only ever sees encrypted data. To restore, use **Settings → Restore…**. It only adds back missing accounts and never deletes any.

## Everyday use

| Action | Mac | Browser |
|---|---|---|
| Copy a code | Click it, or `⌥⌘2` → type → `Enter` | Click it, or `Alt+Shift+T` → type → `Enter` |
| Type a code into the current app | `⌥⌘2` → `⇧Enter` | |
| Fill a 2FA field | | Click the Totem button in the field, or `Alt+Shift+F` |
| Add an account | **+ → Scan screen for a QR code** | **+ → Scan this page** |
| Allow auto-fill on a site | Edit the account → **Sites for browser auto-fill** | Same, or confirm once when asked |

## Commands

| What | Command |
|---|---|
| Install or update | `curl -fsSL https://raw.githubusercontent.com/sanjuantala/authenticator/main/get.sh \| bash` |
| Install from a downloaded ZIP | `cd ~/Downloads && unzip -oq authenticator-main.zip && bash authenticator-main/install.sh` |
| Install with git | `git clone https://github.com/sanjuantala/authenticator.git ~/Totem/source && bash ~/Totem/source/install.sh` |
| Rebuild the Mac app only | `cd ~/Totem/source/mac && ./scripts/build-app.sh` |
| Rebuild without the self-check | `cd ~/Totem/source/mac && SKIP_TESTS=1 ./scripts/build-app.sh` |
| See the last update's log | `tail -50 ~/Library/Logs/Totem/update.log` |
| Quit Totem | `pkill -x Totem` (or `⌘Q` in its menu) |
| Remove old build copies | `rm -rf ~/Totem/source/mac/build` |

<details>
<summary><b>Uninstall</b></summary>

Export an encrypted backup first (**Settings → Import & Export**) if you want to keep your accounts.

```bash
pkill -x Totem
rm -rf /Applications/Totem.app ~/Totem
rm -f ~/Library/Application\ Support/*/NativeMessagingHosts/com.totem.bridge.json \
      ~/Library/Application\ Support/*/*/NativeMessagingHosts/com.totem.bridge.json
# This deletes your vault on this Mac:
rm -rf ~/Library/Application\ Support/Totem
```

Then remove the extension in `chrome://extensions`.
</details>

## Security

| Protection | How |
|---|---|
| Encryption | AES-256-GCM with a key from your master password (PBKDF2-SHA256, 600,000 rounds), everywhere the vault is stored |
| Touch ID | The vault key is sealed by the Secure Enclave and is useless on any other Mac |
| Anti-phishing | On an unsaved site, Totem shows the real address and asks before filling |
| Browser isolation | Web pages never see secrets, only the code for their own site, and only when you ask |
| Mac ⇄ browser link | A private local channel that only accepts Totem's own signed bridge |
| Locking | Auto-lock on a timer, on screen lock and on sleep. Copied codes are cleared after 30 seconds. |

No authenticator protects against malware already running on your Mac. Your master password also can't be recovered, so keep an encrypted export and your sites' recovery codes somewhere safe.

## For developers

```bash
node --test tests/*.test.mjs          # TOTP vectors, vault crypto, merge, importers, Drive
python3 tests/e2e_extension.py        # the extension in real Chrome (needs Playwright)
python3 tests/e2e_sync.py             # two browsers syncing through the Mac bridge
python3 tests/e2e_detect.py           # which fields count as 2FA boxes
python3 tests/swift_members.py        # Mac views only call AppModel members that exist
cd mac && swift run TotemCoreCheck    # Swift core reads the extension's vault format
```

```
extension/   Manifest V3 extension: background.js holds the key, content.js fills fields, lib/ shared logic
mac/         Swift package: TotemCore (crypto, vault), Totem (menu bar app), TotemBridge (browser link)
docs/        VAULT_FORMAT.md, the file format both apps share
tests/       Node and Playwright tests
```

## License

MIT. QR scanning uses [jsQR](https://github.com/cozmo/jsQR) (Apache 2.0) and QR drawing uses [qrcode-generator](https://github.com/kazuhikoarase/qrcode-generator) (MIT).
