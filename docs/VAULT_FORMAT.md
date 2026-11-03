# Totem vault format (v1)

Both apps read and write exactly this. Implementations: `extension/lib/vault.js` and `mac/Sources/TotemCore/Vault.swift`.

## Envelope (what's stored on disk, in the browser, in Drive and in `.totem` exports)

```json
{
  "format": "totem-vault",
  "version": 1,
  "kdf":    { "alg": "PBKDF2-SHA256", "iterations": 600000, "salt": "<base64, 16 bytes>" },
  "cipher": { "alg": "AES-256-GCM", "iv": "<base64, 12 bytes>", "data": "<base64 ciphertext || 16-byte tag>" },
  "updatedAt": 1762156800000,
  "device": "MacBook Pro"
}
```

* Key = PBKDF2-HMAC-SHA256(password normalized to NFC, salt, iterations) → 32 bytes.
* Additional authenticated data = the UTF-8 bytes of `totem-vault-v1`.
* A new random IV is used on every save.
* Two copies made with the same password but different salts can't open each other's data. Totem detects this (`KDF_MISMATCH`) and offers **Join**, which merges both and adopts one key setup.

## Plaintext (inside `cipher.data`)

```json
{
  "accounts": [{
    "id": "uuid", "issuer": "GitHub", "label": "me@example.com",
    "secret": "BASE32SECRET", "algorithm": "SHA1|SHA256|SHA512", "digits": 6, "period": 30,
    "domains": ["github.com"], "order": 0, "pinned": false,
    "createdAt": 0, "updatedAt": 0, "deleted": false
  }],
  "updatedAt": 0
}
```

## Merge rules

* Accounts are matched by `id`. The copy with the newer `updatedAt` wins.
* Deleting leaves a tombstone (`deleted: true`, secret wiped), so a delete on one device isn't undone by another.
* Live accounts with the same secret, issuer and label are collapsed (imports never duplicate).
* Restoring a backup only *adds* accounts that are missing. It never removes any.

## Bridge protocol (extension ⇄ TotemBridge ⇄ app)

Chrome native messaging: a 4-byte little-endian length, then JSON. Requests:

| type | reply |
|---|---|
| `status` | `{ ok, running, unlocked, hasVault }` |
| `getVault` | `{ ok, vault: envelope \| null }` |
| `putVault` `{ vault, base, force? }` | Merges if the app is unlocked with the same key. Otherwise the vault is written only if `base` equals the current `updatedAt` (else `CONFLICT`). |
| `requestKey` | After Touch ID on the Mac: `{ ok, session: { key, salt, iterations }, vault }` |
