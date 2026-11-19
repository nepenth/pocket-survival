# Pocket Assistant: offline-first pass

**Branch:** `ios14-build`, commit `71f018a`. Unsigned, iOS 14.0, llama.cpp pin unchanged.

## Model list (iPhone 11, 4 GB RAM)

Rules: Q4_K_M at 2.1 GB or less, so weights plus context stay within about 2.5 GB. The architecture must be supported by the pinned llama.cpp (4d828bd, 2026-03-02). Every link was checked for HTTP 200, and its exact byte size was recorded on 2026-11-19.

| # | Model | Size | Purpose | Status |
|---|---|---|---|---|
| 1 | LFM2.5 1.2B Instruct | 0.73 GB | Fastest, lightest on battery | Kept, already ran on the device |
| 2 | Atlas First Aid 1.5B (Qwen2.5) | 0.99 GB | First-aid specialist | Kept, already ran on the device |
| 3 | Qwen3.5 2B (unsloth Q4_K_M) | 1.28 GB | Newest general small model (March 2026) | **Added**, not yet tested on the phone |
| 4 | Gemma 2 2B IT | 1.71 GB | Broad general knowledge | Kept |
| 5 | PocketSurvivor 3B (Llama 3.2 3B fine-tune, Apache-2.0) | 2.02 GB, large | Survival specialist: shelter, water, injuries, disasters | **Added** |
| 6 | Llama 3.2 3B Instruct | 2.02 GB, large | Best general quality that fits | Kept |

**Dropped:**
- Qwen2.5 1.5B: it is the same base model as Atlas, and Qwen3.5 2B supersedes it.
- SmolLM2 1.7B: older and weaker than the others at this size.

**Excluded:**
- Gemma 3/3n 4B and Qwen3 4B First-Aid (2.5 GB or more): above the memory ceiling.
- Gemma 4 E2B survival fine-tunes: the pinned llama.cpp doesn't support the Gemma 4 architecture.

**Risk:** Qwen3.5 uses a hybrid recurrent architecture. The pinned llama.cpp supports it (`qwen35`), but it hasn't run on the A13. It can also emit `<think>` blocks; the app now hides them.

## Offline-first changes

- **Home-screen name:** Pocket Assistant.
- **Ready when opened:** the last-used model reloads at launch. This is skipped if the previous load crashed, so a bad model can't cause a crash loop.
- **Chat survives restarts:** the conversation is saved to the phone and restored, because iOS can close the app at any time.
- **One-tap emergency questions** on an empty chat: bleeding, burns, CPR, hypothermia, safe water, signalling for rescue.
- **Readiness prompt:** with no model downloaded, the empty chat says "Download a model now, while you have internet".
- **Safety line:** "AI answers can be wrong. If you can reach emergency services, contact them first."
- **Brief Answers** (on by default, in Settings): asks the model for short replies and caps them at about 320 tokens, to save battery. Ask "continue" for more.
- **Screen stays on while a reply is written:** if the screen locks, iOS suspends the app and GPU work isn't allowed in the background.
- **Model file checks:**
  - before loading, the file must have a GGUF header and its full size; a broken file gets a message instead of a crash
  - before downloading, free space is checked, and the model screen shows it
- **Default instructions for general models** are now survival and first-aid focused, with "say so if unsure". Atlas keeps its own.

## Earlier in this round (commit 0b360db)

- Model loading runs off the main thread, frees the old model first and ignores repeat taps.
- Downloaders update the screen from the main thread, report errors and keep the screen awake.
- Settings → Diagnostics: a step log with free memory, kept across crashes.

## Not done (possible follow-ups)

- **Background downloads** (continuing when the app is closed) need a background URLSession.
- **Offline reference content:** a vetted first-aid reference stored in the app, so key answers don't depend on the model.

## Crash fix (commit 07d53f2)

**Device report:** `CrucibleLLM-2026-11-19-093931.ips`, from the models1 build. The app crashed with SIGSEGV at address 0, inside `ggml_backend_blas_graph_compute` while `llama_decode` was reading the prompt.

**Cause:**
- The llama.cpp xcframework uses Apple's Accelerate maths library through its newer interface, which only exists from iOS 16.4 on.
- Its matrix-multiply function `cblas_sgemm$NEWLAPACK$ILP64` is therefore a weak import, and on iOS 14 it is NULL.
- ggml only hands batches of 32 tokens or more to that code. The short test prompts in the first build stayed under that, but chat-template prompts are always over it.

**Fix:**
- CI now builds the xcframework with `GGML_BLAS_DEFAULT=OFF`, so ggml's own CPU matrix code is used. The submodule pin is unchanged.
- A new CI gate fails the build if any `NEWLAPACK` or `ILP64` symbols are linked again.

## Sources

- [Atlas-FirstAid](https://huggingface.co/Kami574/Atlas-FirstAid)
- [PocketSurvivor-3B](https://huggingface.co/mfielding92/PocketSurvivor-3B)
- [Qwen3.5-2B GGUF (unsloth)](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF)
- [Qwen3.5 small models (Artificial Analysis)](https://artificialanalysis.ai/articles/qwen3-5-small-models)
- [Qwen3.5 small series (Gigazine)](https://gigazine.net/gsc_news/en/20260303-qwen-3-5-small)
- [Qwen-4B-FirstAid-LLM](https://huggingface.co/QWERTYasdgf/Qwen-4B-FirstAid-LLM) (excluded: 2.5 GB)
- [apocalypse-aid-gemma4-e2b](https://huggingface.co/DestinyApocalypse/apocalypse-aid-gemma4-e2b) (excluded: architecture not supported)
- [Edge/mobile LLM leaderboard](https://awesomeagents.ai/leaderboards/edge-mobile-llm-leaderboard/)
- [Best on-device models 2026 (Ertas)](https://www.ertas.ai/blog/best-models-on-device-mobile-ai-2026)
