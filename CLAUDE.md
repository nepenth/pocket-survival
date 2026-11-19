# pocket-survival: notes for agents

Offline survival tools for **one device**: an iPhone 11 (Apple A13, 4 GB RAM) pinned to **iOS 14.7.1**.
The owner installs unsigned .ipa builds from CI and reports back. There is no local iOS 14 toolchain and
no simulator testing: the simulator is not an iPhone 11 on iOS 14, so results there don't count.

## Hard rules
- Deployment target **14.0** for every app and binary; never raise it. `ci/verify-ios14.sh` enforces it.
- CI only: macOS runner with **Xcode 16.4** pinned (Xcode 26+ cannot target below iOS 15, and 16.4 won't
  run on the owner's macOS 27). Builds are unsigned: `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGN_IDENTITY="-"`,
  empty team.
- Keep the bundle id `com.crucible.llmserver` for Pocket Assistant. Changing it makes the update a new
  app, and the downloaded models (GBs) would be lost.
- Version: `MARKETING_VERSION` in the project is raised for each change round. CI sets the build number
  to 100 + run number (builds 1-13 came from the earlier fork).
- iOS 14 SwiftUI: avoid `.buttonStyle(.bordered)`, `.textSelection`, `@FocusState`, `.safeAreaInset`,
  NavigationStack, `URL.path()`, and the two-argument `onChange`.

## Lessons already paid for (don't repeat)
- **Weak-linked newer APIs crash at runtime, not build time.** Accelerate's
  `cblas_sgemm$NEWLAPACK$ILP64` (iOS 16.4+) was NULL on iOS 14 and crashed every prompt of 32+ tokens.
  llama.cpp is built with BLAS off, and CI fails on `NEWLAPACK`/`ILP64` symbols. Check
  `nm -m … | grep "weak external"` whenever a dependency changes.
- **iOS app memory limit is about 2 GB.** Model weights must stay memory-mapped (file-backed).
  `use_extra_bufts = false` stops ggml from repacking weights into app memory; the A13 build would
  otherwise copy a 2 GB model into RAM.
- The A13 GPU (Apple6) can't run ggml's matrix kernels (no simdgroup reduction or matrix ops), so
  llama.cpp is built CPU-only, with `-march=armv8.4-a+fp16` (dot-product and FP16), iPhone 11 or newer
  only. See `apps/PocketAssistant/ci/build-llama-iphone11.sh`.
- The prompt budget is 448 tokens (LibLlama batch 512, context 1024). The A13 re-reads the kept chat
  history on every turn.
- Diagnosing on the device: the owner sends `.ips` files from Settings > Privacy > Analytics Data
  (`CrucibleLLM-*.ips` for crashes, `JetsamEvent-*` for memory kills; most other reports are noise).
  Symbolicate them against the matching CI .ipa: `dwarfdump --uuid`, then `atos -l <load address>`.
  The app's own step log is in Settings > Diagnostics.
  `libimobiledevice` is installed on the Mac (`idevicecrashreport`) if the phone is plugged in.

## Layout
- `apps/PocketAssistant`: on-device chat (llama.cpp submodule pinned at 4d828bd; don't bump it without a
  reason)
- `apps/PocketMirror`: planned; see `docs/ROADMAP.md`
- `docs/`: change reports and the roadmap. The KB packets that define the work are on the owner's KB
  site; ask for links rather than copying their content here.
