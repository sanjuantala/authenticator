# Totem: your own 2FA authenticator

A private authenticator you own end to end: a **menu bar Mac app** and a **Chrome/Brave/Edge/Arc extension**. Both share **one encrypted vault**, sync directly on your Mac, and back up to **your Google Drive**. No third-party servers.

```
 Browser extension ──native messaging──► TotemBridge ──private socket──► Totem.app (menu bar)
        │                                                                     │
        └──────────── encrypted vault file in your Google Drive ◄─────────────┘
```

## What it does

| | Extension | Mac app |
|---|---|---|
| Codes with countdown ring, search, click to copy | ✓ | ✓ |
| Unique "sigil" per service (same look on both) | ✓ | ✓ |
| **Auto-fill**: a Totem button appears on 2FA fields; one click fills the code (split digit boxes too) | ✓ | No |
| **Scan QR from screen**, no phone needed | open tab | any screen, any app |
| **Global hotkey** quick search (Spotlight-style): Enter copies, ⇧Enter *types* the code into the app you're in | `Alt+Shift+T` opens, `Alt+Shift+F` fills | `⌥⌘2` (changeable) |
| Unlock with **Touch ID** | via the Mac app | ✓ |
| Import: Google Authenticator transfer QR, Aegis, 2FAS, Bitwarden, otpauth links, Totem backups | ✓ | ✓ |
| Export: encrypted `.totem` backup, plain otpauth list, per-account QR to move to a phone | ✓ | ✓ |
| Google Drive sync + 30 days of dated backups, restore any of them | ✓ | ✓ |
| Copied codes hidden from clipboard managers and auto-cleared | cleared | hidden + cleared |
| Auto-lock (timer, screen lock, sleep) | ✓ | ✓ |
| Hands out the *next* code in the last 2–3 seconds so it never expires mid-paste | ✓ | ✓ |

## 1 · Install (one line, about 2 minutes)

Needs macOS 14+ and Apple's Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

Paste this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/sanjuantala/authenticator/main/get.sh | bash
```

It downloads the latest version from this repo and installs everything:
* keeps the source in `~/Totem/source`, so later updates build faster,
* updates the extension in whatever folder your browsers already load it from (any Chromium browser),
* builds `Totem.app`, puts it in `/Applications`, and starts it. The Totem mark appears in your menu bar.

If the extension isn't loaded yet: open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and choose `~/Totem/source/extension` (press ⌘⇧G in the picker and paste the path). Then in Totem for Mac, go to **Settings → Backup & Browser → Connect browsers**, and in the extension choose **Use my Mac's vault with Touch ID**.

Prefer to look before you run? Download the ZIP (**Code → Download ZIP**), read `install.sh`, then run `bash install.sh` from the unzipped folder.

## 2 · Updating (one click)

Totem checks this repo for new versions. When one is out, **Install update** appears at the bottom of Totem's menu. Click it: Totem downloads the update, installs it and restarts in about a minute. The browser extension notices its new files and reloads itself; unlock it once afterwards.

You can also check by hand in **Settings → General → Check for updates**, or run the same one-line command again. The update log is at `~/Library/Logs/Totem/update.log`.

## 3 · Google Drive backup (one click)

1. Install **Google Drive for desktop** (<https://www.google.com/drive/download/>) and sign in. Most people already have it.
2. In Totem for Mac, go to **Settings → Backup & Browser** and click **Back up to Google Drive**. That's it.

Totem writes an encrypted copy into your Drive folder, and Google's own app uploads it. There's no Google Cloud project, no API keys, and no sign-in inside Totem. The browser extension shows the Mac's backup status and syncs through the Mac. iCloud Drive, Dropbox, or any synced folder works the same way ("Choose another folder…").

What lands in your Drive:

```
My Drive/Totem/
  totem-vault.json                       ← the live, encrypted vault (merged on every sync)
  backups/totem-backup-2026-11-03.json   ← one per day plus "Back up now" snapshots, newest 30 kept
```

**Restore:** *Settings → Restore…* brings back any account that's missing from a backup. It never deletes anything. On a new Mac, install Totem, create a vault with the **same master password**, turn on backup, and choose **Join and merge** when Totem offers it.

<details><summary>Advanced: Google Drive without the Drive app (Google Cloud OAuth)</summary>

Only needed if you can't install Google Drive for desktop, or want the browser to back up on its own without the Mac.

1. In <https://console.cloud.google.com/>, create a project and enable the **Google Drive API**.
2. **OAuth consent screen**: External, scope `.../auth/drive.file`, add yourself as a test user, then **Publish app**.
3. Create OAuth clients *in the same project*:
   * **Desktop app**, for the Mac: Settings → Backup & Browser → Advanced.
   * **Web application**, for the extension, with redirect URI `https://mdbaiajlghmojiingboeggblieidhpen.chromiumapp.org/oauth2`: extension Settings → "Back up from this browser without the Mac app".
</details>

## Security model

**What protects your codes**

| Layer | How |
|---|---|
| Encryption at rest | AES-256-GCM. The key comes from your master password via PBKDF2-SHA256 with 600,000 rounds. The vault is encrypted everywhere it lives: on the Mac, in browser storage, in Google Drive, and in exports. Google only ever stores scrambled data. |
| Master password | At least 10 characters and rated "Fair" or better by a built-in strength meter. It never leaves your devices and is never stored. |
| Touch ID (Mac) | The vault key is sealed by the Mac's **Secure Enclave** chip. The chip refuses to release it without Touch ID or your Mac password, and the sealed file is useless on any other Mac. |
| Anti-phishing auto-fill | Codes fill automatically only on sites saved for that account. On any other site, even one with "github" in its address, Totem shows the **real address** and asks first, then remembers that site. |
| Browser isolation | Secrets stay in the extension's background worker, and the key is held in memory only. Web pages never see secrets. A page can only ask "the code for *this* site", and Chrome (not the page) reports which site it is. |
| Mac ⇄ browser channel | A private socket (owner-only permissions). Only Chrome, and only for the Totem extension ID, can launch the bridge. The app checks the **code signature** of whatever connects and accepts only the genuine TotemBridge from inside Totem.app. Vaults always travel encrypted. Unlocking the browser through the Mac requires Touch ID every time. |
| Locking | Auto-lock after a set time, and on screen lock and sleep. |
| Clipboard | Copied codes are cleared after 30 seconds. On the Mac they're also marked so clipboard managers don't keep them. |
| Shoulder-surfing | Optional "Hide codes until hovered". |
| Integrity | GCM authentication detects any tampering with a vault file. Every overwrite from the browser keeps the previous file (`vault.before-*.json`). |

**What it can't protect against (no authenticator can)**
* **Malware running as you on your Mac**, such as a keylogger or screen recorder, while Totem is unlocked. Keep macOS updated and install apps only from sources you trust.
* **Losing your master password.** It can't be reset. Keep an encrypted `.totem` export and your sites' recovery codes somewhere safe.
* **Having 2FA codes and passwords in one place.** If someone gets your password manager *and* Totem, 2FA no longer adds protection. Keep them separate. That's one reason this is its own app.

**Your habits matter most**
1. Use a long passphrase, like four random words.
2. Save each site in the account's *Sites for auto-fill*, so auto-fill never needs to ask.
3. If Totem asks "Check the address", read the address before clicking Fill.
4. Never paste a code into a site you reached from an email link.

## Daily use

* **Browser:** on a 2FA page, click the small shield in the code field. Or press `Alt+Shift+F`, or right-click → *Fill 2FA code with Totem*. Matching uses the account's **Websites** list (Edit → "Websites for auto-fill"), with a fallback to the service name.
* **Mac:** press `⌥⌘2` anywhere, type a few letters, hit Enter (copy) or ⇧Enter (type it in).
* **Add an account:** open the site's 2FA setup page, then *Scan this page* (extension) or *Scan screen* (Mac).
* **Moving from Google Authenticator:** in the phone app, go to Transfer accounts → Export, then scan that QR with the Mac's *Scan screen* or by uploading a photo of it.

## Tests

```bash
node --test tests/*.test.mjs          # TOTP RFC vectors, vault crypto, merge, importers, Drive logic (11 tests)
python3 tests/e2e_extension.py        # real Chrome: create/unlock, add, delete, autofill, anti-phishing, QR, import/export (35 checks)
python3 tests/e2e_sync.py             # two browser profiles syncing through the Mac bridge protocol (16 checks)
python3 tests/e2e_detect.py           # which fields count as 2FA boxes: Kite, GitHub, Google, AWS… and look-alikes (15 checks)
cd mac && swift run TotemCoreCheck    # Swift core: opens a vault the extension wrote + RFC vectors (no Xcode needed)
```

## Credits

QR scanning uses [jsQR](https://github.com/cozmo/jsQR) (Apache 2.0) and QR codes are drawn with [qrcode-generator](https://github.com/kazuhikoarase/qrcode-generator) (MIT). Their licenses are in `extension/lib/licenses/`. Totem itself is MIT licensed.

## Layout

```
extension/   Manifest V3 extension (background.js holds the key; popup.*; content.js = autofill; lib/ = shared logic)
mac/         Swift package: TotemCore (vault/crypto/TOTP/importers), Totem (menu bar app), TotemBridge (native host)
docs/        VAULT_FORMAT.md
tests/       Node, Playwright, and the fake bridge used for sync tests
```
