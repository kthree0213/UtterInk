# FlowType parity baseline

Source snapshot: `docs/provenance/legacy-source-import.tsv`.

| Behavior | Rescued implementation evidence | UtterInk replacement gate |
|---|---|---|
| Menu-bar lifecycle | `FlowTypeApp`, `MenuBarRootView` | UtterInk menu and settings launch |
| Toggle and push-to-talk | `HotkeyManager` | Intent-only hotkey tests for both modes |
| Microphone CAF recording and level | `MicrophoneRecorder` | Permission/capture/cleanup adapter tests |
| WhisperKit download/load/transcribe | `FlowCoordinator`, `WhisperModelCacheInspector` | Separate model state plus local transcription integration |
| Language and auto-detect | `SpeechTranscriptionSettings` | Immutable session recognition snapshot |
| Raw and custom output modes | `OutputModesStorage` | Raw-first pipeline and editable modes |
| OpenAI-compatible providers | `LLMProviderCatalog`, `LLMProcessor` | HTTPS/loopback policy, Keychain, sanitized errors |
| Raw fallback | `FlowCoordinator.finishTranscribedPipeline` | Raw persisted before polish; warning on fallback |
| Paste | `TextInjector` | Target/focus validation and guarded restoration |
| Floating status | `DynamicIslandView` | Stage-specific non-authoritative view |
| Onboarding/settings | `OnboardingView`, `SettingsView` | First-success onboarding and complete P0 settings |

The final app may intentionally change unsafe behavior described in the approved design; those changes are not parity regressions.
