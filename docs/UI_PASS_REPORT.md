# Pocket Assistant — chat UI pass, candidate 1

**Build:** `CrucibleLLM-ui1.ipa`, SHA-256 `8c02794669b64ee1a4e99fd0963b776d1ee1081a015b37abcdc9aa07bd5d95e9`
**CI:** nepenth/crucible-llm-server run 44449306937, branch `ios14-build`, commit `ea897d8`, Xcode 16.4 — all gates green (0 errors, Metal 2.3 shader check OK, app + llama.framework minos 14.0, MinimumOSVersion 14.0). Unsigned; llama.cpp pin unchanged.
**Files:** `ContentView.swift`, `LlamaState.swift`, `LibLlama.swift` (+547 / −106).

## What changed
- **Chat screen:** minimal header (title + loaded model name) with one menu: New Chat, Copy Conversation, Settings. The transcript fills the screen; no permanent panels.
- **Readability:** full-width message rows with 16 pt side padding, body font (17 pt default, follows Dynamic Type), extra line spacing, wrapping only. Your messages are lightly tinted; answers sit on the plain background. System colours throughout, so light and dark follow the phone.
- **Input:** bar pinned at the bottom (above the keyboard via SwiftUI's iOS 14 keyboard avoidance), grows from 1 to ~5 lines, placeholder text. Send turns into Stop while a reply is being written; only one reply runs at a time. Tap or drag down on the conversation to dismiss the keyboard.
- **Streaming:** the reply appears in the last message, applied to the screen every 80 ms (not per token) to avoid flicker, with "Thinking…" until the first words arrive. The view follows the newest text.
- **Copying:** long-press any message → Copy; menu → Copy Conversation.
- **Settings sheet:** loaded model + Download or Switch Model (existing model screen), editable Assistant Instructions with Reset, server toggle and address, last-reply speed + benchmark, activity log (loading/server/benchmark messages moved out of the chat).

## Deviations (and why)
1. **Multi-turn memory — touches inference (approved by the owner).** Previously each message was sent alone as raw text, so the model never saw the conversation. Now:
   - The prompt is built with the model's own chat template via `llama_chat_apply_template` (ChatML fallback). Atlas and LFM2.5 both resolve to ChatML.
   - `LibLlama.tokenize` now parses special tokens, so `<|im_start|>`/`<|im_end|>` are real control tokens. Side effect: the HTTP server's ChatML prompts are now tokenized correctly too (the server code itself is unchanged).
   - Recent turns are kept within a **448-token prompt budget**, oldest dropped first. Reasons: LibLlama's batch holds 512 tokens (exceeding it overruns memory), and the A13 re-reads the kept history on the CPU every turn, so a larger budget means a longer wait before the first word. A divider marks "Older messages are no longer remembered"; a message too long to fit gets a notice instead of a crash.
   - Default instructions per model: Atlas gets a first-aid prompt following its model card (numbered steps, life-saving steps first, emergency services); other models get a short general prompt. Editable in Settings.
2. **Sampling parameters are not in Settings.** The app has none to move; temperature 0.4 is hard-coded in the inference code, and exposing it would be a further inference change.
3. **Selection-copy is whole-message, not drag-to-select.** `.textSelection` needs iOS 15; partial selection on iOS 14 needs a UITextView wrapper, which tends to flicker while streaming. Available as a follow-up if wanted.
4. Old Bench/Clear/Copy/Server buttons removed from the chat screen (moved to the menu/Settings).

## Please check on the iPhone 11
1. A 10-message conversation reads comfortably; nothing clipped or scrolling sideways.
2. The input bar is never hidden by the keyboard; dismissing the keyboard shows the full conversation.
3. Streaming looks smooth (no jumping) and the view follows the reply.
4. A follow-up question ("what if it's a child?") is answered in context.
5. Wait before the first word on longer chats, and the speed under Settings → Performance.
6. Stop works mid-reply; New Chat clears.
7. Light and dark mode.
