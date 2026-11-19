# pocket-survival

Offline tools for an iPhone 11 (iOS 14.7.1) used as part of a survival kit. Everything runs on the
phone with no internet after setup: no accounts, no tracking.

| App | Folder | Status |
|---|---|---|
| **Pocket Assistant**: on-device AI chat (llama.cpp, small GGUF models) | [`apps/PocketAssistant`](apps/PocketAssistant) | In use |
| **Pocket Mirror**: offline maps with GPS, reference library (ZIM), survival guide and books | `apps/PocketMirror` | Planned, see [docs/ROADMAP.md](docs/ROADMAP.md) |

## Target device and build rules

- iPhone 11 (Apple A13, 4 GB RAM), iOS 14.7.1. Every app targets **iOS 14.0** and must never raise it.
- Builds are **unsigned .ipa** files made by GitHub Actions (macOS runner, Xcode 16.4: newer Xcode cannot
  target iOS 14) and installed by the owner with a sideloading tool.
- [`ci/verify-ios14.sh`](ci/verify-ios14.sh) fails a build if any binary in the app targets anything newer
  than iOS 14.0.
- Pocket Assistant's llama.cpp is compiled for the A13 only (CPU, dot-product and FP16 instructions).

## Getting a build

Each app has its own workflow under `.github/workflows`. It runs on pushes that touch that app and
uploads `<App>-<version>-build<N>.ipa` as an artifact. Install it over the previous version: the app's data
(including downloaded models) is kept. Don't delete the app first, or its data is deleted with it.

## License

MIT; see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
