# CrucibleLLM — iOS 14.7.1 build (iPhone 11) — change report

**Result:** unsigned Release `.ipa` built; all deployment-target checks pass at iOS 14.0.

| | |
|---|---|
| Artifact | `CrucibleLLM.ipa`, 4,132,187 bytes |
| SHA-256 | `433a9e1e87f0a6523c6b539112ff820756874f11123c3451e82b7f187c87ffd5` |
| CI run | nepenth/crucible-llm-server, Actions run 44385559924 (branch `ios14-build`, commit `a7bef2f`) |
| Runner | GitHub `macos-15` |
| Xcode | **16.4 (16F6)**, iOS SDK 18.5 (SDK minimum deployment target: 12.0) |
| llama.cpp | submodule pin **unchanged** at `4d828bd1ab52` |
| Signing | none (`code object is not signed at all`), as specified |

## Verified in the artifact
- `Payload/CrucibleLLM.app/Info.plist`: `MinimumOSVersion` 14.0, `UIDeviceFamily` [1,2], bundle id `com.crucible.llmserver`
- App binary `CrucibleLLM`: arm64, `LC_BUILD_VERSION minos 14.0`
- `Frameworks/llama.framework/llama`: arm64, `minos 14.0`; framework `MinimumOSVersion` 14.0
- `Frameworks/libswift_Concurrency.dylib` embedded (Swift concurrency back-deployment, needed below iOS 15)
- Embedded ggml Metal shader source compiles at `-std=ios-metal2.3 -target air64-apple-ios14.0` with the iPhone 11's runtime macros (`GGML_METAL_EMBED_LIBRARY`, `GGML_METAL_HAS_BF16`) — no errors
- Compile: 0 errors; warnings only (Swift 6 concurrency diagnostics in DownloadButton/InputButton, one redundant `await` in HTTPServer) — pre-existing, left as-is

## Diff summary (4 files, +62 / −11)
1. **`llama.swiftui.xcodeproj/project.pbxproj`** — all four `IPHONEOS_DEPLOYMENT_TARGET` (2× 16.0, 2× 17.0) → 14.0. *(Required edit 1, as specified.)*
2. **`.github/workflows/build.yml`**
   - `IOS_MIN_OS_VERSION=14.0` on the xcframework step. *(Required edit 2, as specified.)*
   - **Deviation:** pin `/Applications/Xcode_16.4.app` instead of "newest Xcode". The newest on the runner is 26.x; Xcode 26/27 support iOS 15+ deployment targets only (Xcode 27 makes lower targets a build error). Xcode 16.4's SDK accepts down to 12.0.
   - **Deviation:** patch `build-xcframework.sh` in the runner checkout so it honours `IOS_MIN_OS_VERSION`. At the pinned commit the script hard-codes `IOS_MIN_OS_VERSION=16.4` on line 4, overriding the environment — the first successful build produced `llama.framework` with `minos 16.4`. The sed changes it to `${IOS_MIN_OS_VERSION:-16.4}`; the submodule pin is not changed.
   - **Addition:** Metal 2.3 shader compile check (non-blocking) and a post-upload step that fails the job unless the app, `llama.framework` and `Info.plist` all report 14.0.
   - **Addition:** `push` trigger also includes `ios14-build` (GitHub had not registered the workflow on the fork, so `workflow_dispatch` was unavailable).
3. **`llama.swiftui/UI/ContentView.swift`** — **deviation:** `.buttonStyle(.bordered)` (iOS 15+, used twice) replaced with a `BorderedIfAvailable` modifier: bordered on iOS 15+, default style on iOS 14. Missed by the original source scan.
4. **`llama.swiftui/Models/LlamaState.swift`** — **deviation:** `modelUrl.path()` (`path(percentEncoded:)`, iOS 16+) → `modelUrl.path` (iOS 2+; returns the decoded file path). Missed by the original source scan; caught by the compiler.

No changes to app features, the model downloader, dependencies, telemetry, UI libraries, or signing. UI text remains English.

## Notes for on-device validation (owner-run)
- **Metal on A13 / iOS 14:** the shader source compiles at Metal 2.3 on the build host, but the on-device runtime compile is the real test. If a model fails to load with "failed to initialize MTL0 backend", the fallback is a CPU-only xcframework (`GGML_METAL=OFF`). The A13 (Apple6) lacks simdgroup reduction, so ggml runs matrix multiplies on CPU either way.
- **Model URLs:** paste the direct file links, not the repo pages:
  - `https://huggingface.co/Kami574/Atlas-FirstAid/resolve/main/Atlas-FirstAid.Q4_K_M.gguf` (986,048,096 bytes, sha256 `6288edee2291…`)
  - `https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf` (730,895,168 bytes, sha256 `b1b3de114215…`)
  The downloader truncates names at the first "." (files save as `Atlas-FirstAid` and `LFM2`); they still load. Keep the app in the foreground during download.
- **Stretch (on-device server):** not verified; iOS 14 local-network privacy may prompt or block incoming connections.
