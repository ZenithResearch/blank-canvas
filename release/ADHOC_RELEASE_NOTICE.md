## Important: temporary ad-hoc macOS release

This Blank Canvas build is **ad-hoc signed and not notarized by Apple**. The SHA-256 checksum verifies the downloaded bytes, but this build does not provide an Apple-verified publisher identity or notarization.

### Verify the download

Download the ZIP, its release metadata, and `SHA256SUMS` from the official Zenith Research wallpaper page. In the directory containing those files, run:

```sh
shasum -a 256 -c SHA256SUMS
```

Do not open the app if verification fails.

### Open the app

1. Unzip the application and try to open it once.
2. Open **System Settings → Privacy & Security**.
3. Find the message that Blank Canvas was blocked and choose **Open Anyway**.
4. Authenticate with your Mac password or Touch ID, then confirm **Open**.

Only bypass Gatekeeper when the archive came from `https://zenith-research.ca/wallpapers/` and its checksum passed.

