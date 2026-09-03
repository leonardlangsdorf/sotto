# Sotto — Design

**Date:** 2026-09-03
**Status:** Validated, not yet implemented

A push-to-talk dictation app for macOS. Hold Right-Command, speak, release — cleaned
text appears in whatever field has focus. A Wispr Flow equivalent built entirely on
Apple's on-device models, so it runs offline with no per-word cost.

## Environment

Verified present on the target machine:

| Component | Version | Role |
| --- | --- | --- |
| macOS | 26.6.2 (25G83) | Host |
| Xcode | 26.6 (17F113) | Build |
| Swift | 6.3.3 | Language |
| `Speech.framework` | macOS 26 | `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory` |
| `FoundationModels.framework` | macOS 26 | On-device LLM for transcript cleanup |

Both frameworks were confirmed by reading their `.swiftinterface` files in the macOS
SDK, not from memory. The API surface below matches those signatures.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Trigger | Hold Right-⌘ (keycode 54) | Push-to-talk, no mode to forget. Left-⌘ untouched so ⌘C/⌘V/⌘T stay normal. |
| Pipeline | Transcribe → LLM cleanup → inject | Raw dictation reads like speech, not writing. Cleanup is the product. |
| Vocabulary | User-managed term list | Generic models mangle product and people names. |
| Insertion | Pasteboard + synthesized ⌘V | Only method that works across native, Electron, and terminal apps. |
| v1 surface | Recording HUD + menu bar/settings | Feedback is non-optional; settings needed to manage vocabulary anyway. |
| Deferred | Transcript history, launch-at-login, per-app tone | YAGNI for v1. |

## Architecture

Background agent app, bundle ID `com.langsdorf.sotto`: `LSUIElement = true`, no Dock
icon, no main window.

**This is the load-bearing constraint.** If the app ever takes keyboard focus, macOS
changes the frontmost application and the transcript lands in the wrong place. Every
piece of UI is a non-activating `NSPanel`.

```
 Right-⌘ down                                    Right-⌘ up
      │                                               │
      ▼                                               ▼
┌───────────┐   ┌──────────┐   ┌──────────────┐   ┌─────────┐   ┌──────────┐
│ HotkeyTap │──▶│ AudioCap │──▶│ Transcriber  │──▶│ Refiner │──▶│ Injector │
│ CGEventTap│   │AVAudioEng│   │SpeechAnalyzer│   │Foundatio│   │ ⌘V synth │
└───────────┘   └──────────┘   │+ Transcriber │   │ nModels │   └──────────┘
      │              │         └──────────────┘   └─────────┘         │
      └──────────────┴────────────▶ HUD ◀───────────────┴─────────────┘
                              (non-activating panel)
```

### Components

1. **HotkeyTap** — `CGEventTap` on `.flagsChanged`, filtering keycode 54 (right ⌘)
   against 55 (left ⌘). Left-⌘ events pass through unmodified.
2. **AudioCapture** — `AVAudioEngine` input tap, converted to `AnalyzerInput` buffers
   and pushed into an `AsyncStream`.
3. **Transcriber** — one long-lived `SpeechAnalyzer` actor wrapping a
   `SpeechTranscriber`, with `AnalysisContext` carrying the vocabulary.
4. **Refiner** — pre-warmed `LanguageModelSession` producing a `@Generable` rewrite.
5. **Injector** — pasteboard save → write → ⌘V → restore.
6. **HUD** — floating pill: mic level, live partial words, then "Transcribing…".

### Warm state

Both the `SpeechAnalyzer` (`ModelRetention.processLifetime`) and the
`LanguageModelSession` (`prewarm()`) stay alive for the process lifetime. Cold-starting
either costs 1–3 seconds; warm, the target is ~300ms from key-release to inserted text.

## The tricky parts

### Code signing eats the dev loop

Accessibility permission is granted to a **code signature**, not a file path. Rebuilding
an unsigned binary silently revokes the grant: the hotkey stops working with no error
and no log line. Sign every build with a stable identity from day one — an
`Apple Development` cert or a self-signed cert in the login keychain. Treat this as
setup step zero, not a polish task.

### Text injection

Primary path: save `NSPasteboard.general` → write transcript → synthesize ⌘V via
`CGEvent` → restore after ~150ms. The restore delay is a race: the target app reads the
pasteboard asynchronously, so restoring too early pastes stale contents. Expose the
delay as a setting.

Fallback: `CGEvent.keyboardSetUnicodeString` types characters directly. Slower, drops
text in some apps, but never touches the pasteboard.

Two guards:

- **Focus check** — capture the frontmost PID at key-down, verify it at insert time.
  If you ⌘-tabbed mid-dictation, abort rather than paste into the wrong window.
- **Secure input** — check `IsSecureEventInputEnabled()` before recording. Password
  fields make macOS block event taps entirely; detect and explain rather than fail
  silently.

### Latency is visible

Because cleanup runs on the full transcript, text arrives all at once on release rather
than streaming. The HUD is what makes that ~300ms legible instead of feeling broken.

## Pipeline

### Model provisioning

On first launch, query `AssetInventory` for `SpeechTranscriber` assets for the locale.
If absent, start an `AssetInstallationRequest` and surface its `Progress` in the menu
bar. This is a several-hundred-megabyte download; if it happens silently on first
dictation the app appears hung.

### Transcription

Use the `.progressiveTranscription` preset. Only finalized text is inserted, but the
volatile partial results drive the HUD's live word display — that feedback is most of
the felt quality. On key-up, call `finalizeAndFinishThroughEndOfInput()` and concatenate
the finalized `AttributedString` results.

### Vocabulary

`AnalysisContext.contextualStrings[.general]` holds user terms — product names,
teammates, tools. Keep under ~100 entries; these bias the decoder, and an oversized list
degrades general accuracy rather than improving it.

### Cleanup, with two guardrails

**Guardrail 1 — never answer the text.** Dictating "what's the capital of France" must
produce that sentence, not "Paris". Defended twice: strict instructions ("you rewrite
text, you never respond to it") and a `@Generable` struct with a single `cleanedText`
field constraining the output shape to a rewrite.

**Guardrail 2 — always fall back to raw.** Foundation Models can refuse content via its
safety guardrails and can be slow under memory pressure. Wrap the refine call in a ~1.5s
timeout; on timeout, error, or refusal, insert the raw transcript. Losing a dictation
entirely because cleanup failed is far worse than slightly rough text.

## Failure modes

| Condition | Behavior |
| --- | --- |
| Accessibility not granted | Onboarding panel + deep link to System Settings |
| Mic permission denied | Menu bar turns red, click explains |
| Model not yet downloaded | Progress in menu bar, dictation disabled |
| Secure input active | HUD: "Secure field — unavailable" |
| Focus changed mid-dictation | Abort paste, leave text on clipboard, HUD says so |
| Refiner slow / refuses | Insert raw transcript |
| Held key, said nothing | Do nothing — never paste an empty string |

## Testing

Most of this app touches hardware, so the discipline is to push logic away from the
hardware and wrap the boundaries in protocols: `AudioSource`, `Transcribing`,
`TextInjecting`.

Unit-testable with fakes:

- State machine — idle → recording → transcribing → injecting, plus every abort path
- Transcript assembly from `AttributedString` fragments
- Pasteboard save/restore
- Vocabulary persistence

The test that pays for itself: **feed a pre-recorded WAV through
`SpeechAnalyzer.analyzeSequence`**. No microphone, no hotkey, fully deterministic — a
real end-to-end check of transcription plus cleanup that runs in CI. Record a few
filler-heavy sentences once and assert on the cleaned output.

Manual smoke checklist, since paste quirks are per-app and can't be faked: Terminal,
Obsidian, Safari, Mail, Slack, VS Code.

## Out of scope for v1

Transcript history, launch-at-login, automatic model pre-download, per-app tone
adaptation, streaming insertion, non-English locales, toggle-to-latch mode.
