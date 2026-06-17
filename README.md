# nfc-fido-pam

Authenticate on Linux with a **FIDO2 NFC authenticator read over PC/SC** — an NFC
implant, a contactless security key, a phone-as-key — via PAM. Tap to unlock,
`sudo`, or log in.

It is the **auth layer** that sits on top of a PC/SC contactless reader such as
[`thinkpad-nfc-pcsc`](https://github.com/dapperdivers/thinkpad-nfc-pcsc) (which
turns a ThinkPad's embedded NXP NFC controller into a PC/SC reader). Any PC/SC
reader that can see a FIDO2 applet works.

## Why this exists

There is **no standard packaged PAM module** for FIDO2 over NFC/PC-SC:

- `pam_u2f` (Yubico) is **USB-HID only** — it enumerates via libfido2's
  `fido_dev_info_manifest()`, documented as "only USB HID devices."
- libfido2's PC/SC backend (`USE_PCSC`) is experimental, off by default, and not
  built in Debian/Ubuntu/Parrot.
- `pam_p11`/`pam_pkcs11` do PKCS#11/PIV (X.509), **not** FIDO2 CTAP2.

So a small custom verifier is genuinely the right tool. This project keeps it
*proper* by using the standard PAM **helper-separation** pattern (like
`pam_unix`→`unix_chkpwd`): a thin glue layer invokes a standalone verifier that
does the device + crypto work in a clean process.

## Architecture

```
authenticator ──NFC──> PC/SC reader ──> pcscd ──> nfc-fido-verify ──> pam_exec ──> PAM
                        (e.g. thinkpad-nfc-pcsc)   (this repo)         (this repo)
```

| Layer | Component | Role |
|---|---|---|
| Transport | a PC/SC reader (e.g. `thinkpad-nfc-pcsc`) | expose the FIDO2 token as a PC/SC reader |
| **Verifier** | `nfc-fido-verify` | poll PC/SC, CTAP2 `get_assertion`, exit 0 on a valid tap |
| **Glue** | stock `pam_exec` + a `/etc/pam.d` line | run the verifier, map its exit code to PAM |

Running the verifier as a **subprocess** is the whole trick: a PAM *client* that
can't do PC/SC in-process — notably a **Nix-built lock screen on a non-NixOS host**,
whose loader can't pull in the host's `libfido2`/`pyscard`/`libssl` — still
authenticates, because the verifier runs under the system interpreter where those
libraries resolve normally.

## Install

Dependencies: `pcscd`, `python3-fido2`, `python3-pyscard`, `libpam-modules`
(provides `pam_exec`). A PC/SC reader that sees your token (verify with
`opensc-tool --list-readers`).

```sh
sudo apt install ./nfc-fido-pam_*_all.deb
# or from source:
./build.sh && sudo apt install ./dist/nfc-fido-pam_*_all.deb
```

## Enrol

```sh
sudo nfc-fido-enroll --user "$USER"     # tap when prompted
nfc-fido-verify --user "$USER" --timeout 15   # tap; should print "verified" and exit 0
```

Enrollment stores only **public** data (`/etc/nfc-fido/<user>`: rp-id, credential
id, COSE public key). The private key never leaves the authenticator; every
auth is a fresh random-challenge signature.

## Wire it into PAM

Add the verifier as a `sufficient` method ahead of your existing one. See
[`pam/`](pam/) for full examples. Normal distro PAM client (short form):

```
auth  sufficient  pam_exec.so  expose_authtok quiet  /usr/lib/nfc-fido/nfc-fido-verify --pam --skip-if-authtok --timeout 3
```

- `--pam` reads the user from `$PAM_USER` (set by `pam_exec`).
- `sufficient` → a valid tap authenticates; anything else falls through to the
  next method (password, fingerprint, …).
- `expose_authtok` + `--skip-if-authtok` → typing a password skips the implant
  poll entirely, so a typed login isn't delayed; a bare submit still polls for a tap.

For a **Nix-built hyprlock** (or any client whose libpam only searches the Nix
store), name every module by absolute path — see
[`pam/hyprlock.example`](pam/hyprlock.example).

## Security notes

- Only public key material is stored on disk; assertions are challenge/response.
- The verifier never logs the authtok; `--skip-if-authtok` only tests it for
  emptiness.
- A failed/forged tap returns non-zero, which under `sufficient` simply falls
  through to the next method — it does not hard-deny.

The verifier follows the WebAuthn §7.2 assertion-verification algorithm (adapted
for a local, non-browser `clientDataHash`): fresh CSPRNG challenge, `rpIdHash`
binding, **User-Present flag**, BE/BS backup-state consistency, credential-id
binding (tolerating the single-allowList omission), algorithm pinning to the
enrolled COSE key, and the **signature-counter clone check** (§6.1.1).

**Clone detection (`--counter-policy`, `--state-dir`).** Each success advances a
per-credential high-water mark; an assertion whose counter does not increase is
the spec's cloned-authenticator signal. Policy is `strict` (reject, default),
`warn` (allow + log), or `off`. Constant-0 authenticators (no counter support)
are tolerated per spec, never falsely flagged. The high-water mark defaults to a
**per-user** path (`~/.local/state/nfc-fido/`, or `/var/lib/nfc-fido` as root):
this defends against an *external* physical clone (an attacker at the lock screen
can't write your state), but not against the account owner resetting their own
counter — point `--state-dir` at a root-owned, privileged-helper-managed location
for that. If the legitimate token's counter ever resets, clear its state file.
- **`--require-uv`** enforces User-Verification, for tokens with a PIN/biometric;
  a tap-only implant never sets UV, so leave it off for those.

## License

Packaging and glue: GPL-2.0. See [LICENSE](LICENSE).
