# Sotto

Push-to-talk dictation for macOS. Hold **Right ⌘**, speak, release — cleaned text
appears in whatever field has focus.

Everything runs on-device: Apple's `SpeechAnalyzer` for transcription and
`FoundationModels` for turning spoken phrasing into written phrasing. No network,
no API key, no per-word cost.

Requires macOS 26 and Xcode 26.

## Build and run

```bash
Scripts/create-signing-identity.sh   # once — see "Signing" below
Scripts/build.sh
open build/Sotto.app
```

Sotto is an agent app: no Dock icon, no windows. It appears in the menu bar and
never takes keyboard focus — the moment it did, macOS would change the frontmost
app and your text would land in the wrong place.

### First run

Two permissions, both prompted for:

| Permission | Why |
| --- | --- |
| Accessibility | Watch for Right-⌘ and synthesize the paste keystroke |
| Microphone | Hear you |

On first launch Sotto also downloads the speech model for your locale — several
hundred megabytes, with progress shown in the menu bar. Dictation is disabled
until it finishes.

### Signing

**Accessibility permission is granted to a code signature, not a file path.** An
ad-hoc-signed binary gets a new identity on every rebuild, so macOS silently
revokes the grant and the hotkey stops working with no error and no log line.

`Scripts/create-signing-identity.sh` creates a self-signed code signing
certificate in your login keychain. Signing with a certificate makes the
designated requirement

```
identifier "com.langsdorf.sotto" and certificate leaf = H"<cert hash>"
```

which stays identical across rebuilds even as the binary's cdhash changes — and
that is what TCC keys on, so the Accessibility grant persists.

The certificate does not need to be trusted by the system, so this needs no
admin password. macOS may show one keychain prompt for your login password. To
undo it, delete "Sotto Local Signing" in Keychain Access.

If you have an Apple Developer certificate, `Scripts/build.sh` picks it up
automatically, or set `SOTTO_SIGN_IDENTITY` to choose one.

## How it works

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

`Sources/SottoCore` holds the hardware-free logic — the state machine, transcript
assembly, vocabulary, settings — so the paths that are near-impossible to
reproduce by hand are unit tested. `Sources/SottoKit` holds everything that
touches CoreGraphics, AVFoundation, Speech, and AppKit.

The full design, including the failure modes each component handles, is in
[docs/plans](docs/plans/2026-09-03-sotto-dictation-design.md).

### Cleanup is off by default

Raw transcripts arrive in about a third of a second and are already punctuated
and capitalized. Cleanup adds filler removal and tighter phrasing, but costs
roughly **0.4s per word of output** — a 40-word dictation would take ~16s. Turn
it on in Settings when the text matters more than the speed.

Measured on an M-series Mac:

| Output length | Time |
| --- | --- |
| 9 words | 1.06s |
| 11 words | 3.82s |
| 15 words | 6.95s |

The cleanup deadline scales with transcript length rather than being fixed, so
long dictations are not cut short and short ones are not made to wait.

### Cleanup guardrails

When enabled, the refiner rewrites speech into writing — filler removed,
punctuation kept, your words preserved. Two things stop it misbehaving:

- Dictating *"what's the capital of France"* must produce that sentence, not
  "Paris". Enforced by strict instructions plus a `@Generable` type whose only
  field is the rewrite.
- Every failure path falls back to the raw transcript. Losing a dictation
  because a cosmetic step timed out would be far worse than rough text.

## Settings

Menu bar ▸ Settings.

- **Cleanup** — on/off (default off), and the maximum wait before falling back to raw
- **Insertion** — paste (default, works everywhere) or type characters (slower,
  never touches the clipboard)
- **Vocabulary** — names and jargon to bias recognition toward, capped at 100.
  These bias the decoder; a longer list is not a better one.

Stored at `~/Library/Application Support/Sotto/settings.json`.

## Development

```bash
swift test                 # 35 tests; speech tests need the model installed
swift build                # just compile
```

The speech tests run recorded WAVs through `SpeechAnalyzer` — no microphone, no
hotkey, no Accessibility permission. Fixtures are generated by `say`, so they are
identical on every run. They skip themselves if the speech model is not yet
installed.

Watch the running app:

```bash
log stream --predicate 'subsystem == "com.langsdorf.sotto"' --level debug
```

### Driving the app without the keyboard

The hotkey path cannot be exercised from a script — synthesizing a keypress
needs Accessibility for the *posting* process. Instead the app can be driven
directly when launched with `SOTTO_DEBUG=1`:

```bash
open --env SOTTO_DEBUG=1 build/Sotto.app
```

It then listens for two distributed notifications, which run the real delivery
and transcription paths rather than a parallel test-only one:

| Notification | userInfo | Effect |
| --- | --- | --- |
| `com.langsdorf.sotto.debug.injectText` | `text` | Insert that text into the frontmost app |
| `com.langsdorf.sotto.debug.dictateFile` | `path` | Transcribe a WAV, clean it up, insert it |

This is off unless the environment variable is set — it posts synthesized
keystrokes into whatever is frontmost, which no normally-launched build should
expose.

### Manual smoke checklist

Paste behaviour is per-app and cannot be faked, so after any change to the
injector, check: Terminal, Obsidian, Safari, Mail, Slack, VS Code.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Hotkey does nothing after a rebuild | Ad-hoc signing revoked the Accessibility grant — see Signing |
| "Secure field — dictation unavailable" | A password field is focused; macOS blocks event taps entirely |
| Occasionally pastes the previous clipboard | Raise the clipboard restore delay in Settings |
| Text goes nowhere | You switched apps mid-dictation; the transcript is on your clipboard |
| Cleanup toggle is disabled | Apple Intelligence is off or unavailable on this Mac |
