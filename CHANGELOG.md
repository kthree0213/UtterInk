# Changelog

All notable changes to UtterInk will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Public contribution guidance covering test-driven development, privacy-safe
  fixtures, deterministic generated assets, accessibility review, and
  dependency license compatibility.
- Community behavior standards and structured issue and pull request templates
  with privacy, security, testing, and accessibility prompts.
- Automated validation for public documentation structure, repository-relative
  links, sensitive-data canaries, and required public files.

## [0.1.0]

This section describes the current pre-release source baseline; it does not
indicate that an installable package has been published.

### Added

- A macOS menu-bar dictation experience with an optional floating recorder,
  Toggle and Hold to Talk shortcut modes, and explicit recording state.
- Local speech transcription through WhisperKit with runtime download and cache
  management for the pinned `base`, `small`, and `large-v3` model revisions.
- Raw text output by default and optional OpenAI-compatible text polishing with
  user-configured profiles and credentials protected by macOS Keychain.
- Text-only history for the newest 20 sessions, raw-result recovery, per-session
  deletion, and clear-history controls.
- Guarded Automatic Paste with bounded in-memory clipboard recovery, plus Copy
  Only, explicit Copy, and Paste Again delivery paths.
- Sanitized local diagnostics, explicit permission status, privacy and security
  documentation, third-party notices, and separate trademark guidance.
