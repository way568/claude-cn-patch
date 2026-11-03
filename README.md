# claude-cn-patch

> Unlock the official Simplified Chinese UI hidden inside Claude Desktop for macOS — one script, Anthropic's own 34,443-entry dictionary, no Node.js or dev tools required.

**English** · [简体中文](./README.zh-CN.md)

## 📸 Preview

| Settings | Language picker |
|---|---|
| ![Settings in Simplified Chinese](screenshots/settings-zh.png) | ![Language picker with Chinese entry](screenshots/language-picker-zh.png) |

## ✨ Features

- **Official dictionary**: Anthropic's own 34,443 UI translations (not community machine translation)
- **Zero dependencies**: only macOS built-ins (bash + python3 + codesign)
- **Original app untouched**: all changes happen in a `Claude-CN` copy only — delete the copy to roll back
- **Fool-proof by design**: running-instance detection, disk-space check, per-file hash self-verification before replacing anything, drift-aware anchor patching

## 🚀 Quick Start

```bash
git clone https://github.com/way568/claude-cn-patch.git
cd claude-cn-patch
bash patch.sh
```

1. The script creates `/Applications/Claude-CN.app` and patches it (~2 min)
2. Fully quit the original Claude (menubar icon → Quit Claude — ⚠️ closing the window is not enough)
3. Open Claude-CN → choose 中文（简体） in the language menu once → Chinese from then on

Custom paths: `bash patch.sh /path/to/MyClaude.app`; override the source app with `SRC_APP=/path/to/Claude.app bash patch.sh`.

## 📋 Compatibility

| Item | Status |
|---|---|
| Verified app version | 4.4212.0 (2026-10-30 build, arm64) |
| OS | macOS (Apple Silicon; Intel untested) |
| Other versions | Anchors are located by content search, so minor version drift adapts automatically; on larger drift the script reports each skipped step without damaging the app |

## 🔧 How It Works

Anthropic already ships the whole Chinese UI machinery — the dictionary lives on their CDN and the i18n pipeline is built into the app — but `zh-Hans` is not on the client-side release list. This patch makes four small changes to the copy's `ion-dist.asar`:

1. Append `zh-Hans` to both language lists in the app code (catalog index / picker list)
2. Append the Chinese entry at the picker render point
3. Install the official dictionary (`catalogs/`)
4. Disable the Electron asar integrity fuse (bypassing the plist fingerprint + framework digest layers), then ad-hoc re-sign

No UI strings are replaced, no network requests are touched, and the original app is never modified.

## ❓ FAQ

| Question | Answer |
|---|---|
| It asks me to reconfigure the model gateway / sign in | The copy has a different signature and cannot read the original app's keychain items — re-enter once and you're set |
| Chinese disappeared after a Claude update | Updates overwrite the patch — re-run `bash patch.sh` |
| How do I go back to the official app? | Just use the original Claude app (never modified), or delete Claude-CN |
| "App is damaged and can't be opened" | Re-run the script (re-signs the copy) |
| Some newer UI is still English | The dictionary is the official 2026-10 release; strings added in newer app versions fall back to English |
| What happens when Anthropic ships Chinese officially? | This project retires — delete the copy and use the original |

## 📜 Dictionary Provenance & Copyright

The two dictionaries under `catalogs/` are extracted from the official Claude UI translation files served by Anthropic's CDN. Copyright belongs to Anthropic. They are included solely for local UI interoperability and are **not covered by this repository's open-source license**. They will be removed upon request from the rights holder (by which point the official Chinese UI should be generally available).

## 🤝 Contributing

When a major Claude update shifts the patch anchors, PRs are welcome:

1. Run `bash patch.sh` and collect the steps reported as "anchor drift"
2. In the new `ion-dist.asar`, locate the new anchors using the relevant feature keywords (`i18nReleased`, `data-i18n-catalogs`, the language-picker render function)
3. Update the anchor strings in `patch.sh` and submit a PR with a screenshot of the working result

## ⚖️ Disclaimer

For personal study and research only. Claude is a trademark of Anthropic Inc.; this project is not affiliated with them. Use at your own risk.

## 📝 Changelog

See [CHANGELOG.md](CHANGELOG.md).