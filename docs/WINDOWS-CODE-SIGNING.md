# Windows release signing

Official Windows releases must be signed with an Authenticode certificate. A
SHA-256 file hash proves integrity after download, but it does not establish a
trusted publisher and does not prevent Microsoft Defender reputation warnings.

The GitHub Actions workflow expects these repository secrets:

- `WINDOWS_SIGNING_CERT_BASE64`: base64 encoded PFX certificate, one line.
- `WINDOWS_SIGNING_CERT_PASSWORD`: PFX password.
- `WINDOWS_SIGNING_TIMESTAMP_URL`: optional timestamp URL; the default is
  `https://timestamp.digicert.com`.

The signing certificate and password must be added through GitHub repository
Secrets. Do not commit the PFX file, its password, or a private key.

Pushes to `main` still produce a scanned preview artifact. A version tag cannot
publish an official Release until signing succeeds and `Get-AuthenticodeSignature`
reports `Valid` on the final `caidattroly.exe`.
