# Phat hanh bo cai Windows

## Tao ban build thu cong

Tren Linux co san NSIS, chay:

```bash
PYTHON_BIN=python3 ./build-native-bundle.sh
NSIS=/path/to/makensis PYTHON_BIN=python3 RELEASE_VERSION=2026.11.17 ./build-windows-installer.sh caidattroly.exe
```

Script tao `caidattroly.exe`, file checksum va bundle native. Cac artifact nay
duoc bo qua khoi Git va duoc dua len GitHub Release.

## Phat hanh tu dong

1. Cap nhat source, module/skill va `MANIFEST.txt`.
2. Chay test local.
3. Tao tag phien ban theo ngay dang `vYYYY.MM.DD` (vi du `v2026.11.17`) va push tag:

```bash
git tag v2026.11.17
git push origin v2026.11.17
```

GitHub Actions chay tren Windows, cai NSIS, build bo cai, tao checksum va
dang file vao GitHub Release. Khong commit Telegram token, API key, Zalo
session, cookie, database, runtime state hoac file `.env`.

`caidattroly.exe` la bo cai moi. Ban hien tai khong tu dong nang cap cac
instance da cai; muon cap nhat tai cho can them luong upgrade rieng.
