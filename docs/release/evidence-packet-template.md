# UtterInk 0.1.0 Release Evidence Packet Template

This document defines the evidence requirements and reviewer worksheet for a
final local evidence packet; it is not a byte-for-byte rendering template. The
collector emits a compact packet with the same mandatory identity and ordered
failure, pass, and outstanding-approval sections plus sanitized record
digests. It intentionally does not auto-fill the reviewer acknowledgement or
invent observations and remediation text. The generated packet is a review
artifact, not a writable approval record and not a publication asset.
Reviewing, signing, or accepting it does **not**
authorize a GitHub push, Apple submission, beta transfer, public-visibility
change, GitHub Release, or any other external action.

`Scripts/release/collect-evidence.py` computes the packet from closed,
type-specific evidence records. Only `candidate.json` is validated against
[`evidence-schema.json`](evidence-schema.json); the other Task 6 record types
are checked by the collector's closed typed validators. This template is not a
general JSON Schema and must not be used to coerce an unrelated record into a
passing evidence class.

## Packet identity

| Field | Required value |
|---|---|
| Computed status | `NOT_RELEASE_READY` until every required gate is present and passing |
| Expected status supplied to collector | `READY` or `NOT_RELEASE_READY` |
| Product/version/build | `UtterInk 0.1.0 (1)` |
| Repository scope | `<approved owner/repository or approved local no-origin scope>` |
| Branch | `<approved branch>` |
| Candidate commit | `<40 lowercase hexadecimal characters>` |
| Candidate tree | `<40 lowercase hexadecimal characters>` |
| Candidate record SHA-256 | `<64 lowercase hexadecimal characters>` |
| Final DMG filename | `UtterInk-0.1.0-arm64.dmg` |
| Signed pre-staple approved SHA-256 | `<64 lowercase hexadecimal characters>` |
| Notarization approval record SHA-256 | `<64 lowercase hexadecimal characters>` |
| Final post-staple DMG SHA-256 | `<64 lowercase hexadecimal characters>` |
| Final post-staple DMG size | `<integer bytes>` |
| Packet generation timestamp | `<RFC 3339 UTC timestamp>` |

Every evidence record must bind to the same approved repository/branch scope,
candidate commit, candidate record, and applicable pre- or post-staple hash.
The notarization approval hash must bind the signed pre-staple bytes. Manual and
Gatekeeper results must bind the immutable final post-staple bytes. A hash or
commit mismatch is malformed evidence, not a failed gate that can be waived.

## Computed status rules

- `READY` is possible only when every required evidence class is present,
  structurally valid, mutually consistent, current, and passing.
- A structurally valid packet with any recognized missing, `fail`, or
  `not-run` gate computes `NOT_RELEASE_READY` and lists every gap.
- Malformed, contradictory, unsafe, stale, unknown, or candidate-mismatched
  evidence is rejected. It cannot be relabeled `NOT_RELEASE_READY` to launder
  the input.
- The collector writes its computed status before comparing it with the
  mandatory `--expect-status` value. A mismatch exits nonzero.
- The summary order is mandatory: failures and missing gates first, passed
  automated/manual gates second, outstanding external approvals third.

## 1. Failures and missing gates

List every recognized `fail`, `not-run`, missing, stale, or incomplete gate.
Do not omit a gap because another class passed.

| Gate code | Evidence class | Status | Candidate/final-hash binding | Concise sanitized reason | Required remediation |
|---|---|---|---|---|---|
| `<stable code>` | `<class>` | `fail`, `not-run`, or `missing` | `<commit and applicable hash>` | `<reason>` | `<fresh evidence required>` |

If this section contains any row, the packet remains `NOT_RELEASE_READY`.

## 2. Passed automated and manual gates

Include only collector-validated passing records. Do not manually copy a gate
into this section.

| Gate code | Evidence class | Status | Candidate/final-hash binding | Sanitized evidence reference | Observation |
|---|---|---|---|---|---|
| `<stable code>` | `<class>` | `pass` | `<commit and applicable hash>` | `<safe relative reference or digest>` | `<concise result>` |

## Required evidence inventory

The checked-in template begins with every class as `not-run`; it therefore
describes a `NOT_RELEASE_READY` packet until real, collector-valid evidence
replaces each entry.

| Required evidence class | Initial status | Required binding and contents |
|---|---|---|
| Candidate, toolchain, and dependency lock | `not-run` | Schema-valid `candidate.json`; exact commit/tree; clean state; pinned Xcode/SDK/Swift/XcodeGen; `Package.resolved` path and SHA-256. |
| Approved repository/branch scope and exact commit | `not-run` | Approved repository or explicit local no-origin scope, branch, exact 40-character commit, and consistent release tag. |
| Complete sorted public file list | `not-run` | Exact-commit file inventory, stable sort, no unreviewed or unexpected public file. |
| Full-history secret/private-data scan | `not-run` | Complete history and working-tree scope, expected origin scope, passing result, and no sensitive object left in history. |
| Source, IP, provenance, license, and model-notice review | `not-run` | Rights manifest; Apache-2.0 and NOTICE review; third-party dependency/model versions, sources, licenses, and download/redistribution behavior. |
| Tests, build, and unsigned CI smoke | `not-run` | Exact-candidate automated tests, clean build, policy checks, generated-project check, and unsigned arm64 packaging smoke; unsigned output is not a release artifact. |
| Identity approval | `not-run` | Approved production identity family, exact deterministic assets, source provenance, and final user approval. |
| Competitor-similarity review | `not-run` | Separate documented result for the exact production identity; not inferred from identity approval. |
| Trademark-risk review | `not-run` | Separate documented result for the exact production identity; no implication of paid legal clearance. |
| Accessibility matrix | `not-run` | Complete pass/fail/not-run records from [`manual-verification-matrix.md`](manual-verification-matrix.md) for every shipped localization, surface, and state. |
| Signing, entitlements, and codesign | `not-run` | Exact-candidate inside-out signing, hardened runtime/timestamp, allowlisted entitlements/components, strict nested and outer verification, and certificate/team binding without certificate body. |
| Notarization submission, log review, and staple validation | `not-run` | One consumed artifact-scoped approval, one exact pre-staple upload, accepted result, complete sanitized log review including warnings, stapling, and staple validation. |
| DMG identity and manifest | `not-run` | Exact filename, integer size, allowlisted content manifest, signed pre-staple approved SHA-256, notarization approval hash, and immutable final post-staple SHA-256. |
| Local quarantined-copy Gatekeeper | `not-run` | Byte-identical quarantined test copy, DMG/app Gatekeeper assessments, first launch/relaunch, original untouched, and final-hash binding. |
| Second-Mac clean-user offline Gatekeeper | `not-run` | Distinct physical supported Apple Silicon Mac, clean user, no development certificate/cached ticket, quarantine preserved, offline first launch, and final-hash binding. Another account on the development Mac is invalid. |
| Privacy, security, docs, links, and Markdown | `not-run` | Passing privacy/security/docs/link/Markdown validation plus rendered English README, Chinese README, and Privacy previews bound to the exact commit. |
| Known issues and exact support/non-goal scope | `not-run` | macOS 14+, Apple Silicon/arm64, English P0 UI, manual updates, no Intel/cloud sync/live transcription/audio history, and all reviewed known issues. |
| Verified release asset inventory | `not-run` | Collector-validated `release-assets-evidence.json` for the exact public DMG, source archives, checksums, and release notes; no extra asset. |

Missing evidence for any inventory row keeps the packet
`NOT_RELEASE_READY`. The collector must list every missing or failed class, not
stop after the first recognizable gap.

## Manual evidence summary

Summarize only records that satisfy the per-row fields in the manual matrix:
explicit `pass`/`fail`/`not-run`, tester label, Apple Silicon model class,
supported macOS version, RFC 3339 timestamp, exact final post-staple SHA-256,
locale, and concise sanitized observation.

| Manual class | Required coverage | Status | Exact final SHA-256 | Evidence reference |
|---|---|---|---|---|
| Minimum macOS 14.x real-hardware runtime | Install, first launch/relaunch, onboarding, permissions, model, recording, History, provider, delivery, accessibility smoke | `not-run` | `<final hash>` | `<reference>` |
| Complete accessibility surface/state matrix | Menu bar, floating recorder, onboarding, every Settings group, History, last result, dialogs, every state, every shipped localization | `not-run` | `<final hash>` | `<reference>` |
| Local quarantined-copy Gatekeeper | Byte-identical copy, preserved immutable original, DMG/app assessment, launch/relaunch | `not-run` | `<final hash>` | `<reference>` |
| Second-Mac clean-user offline Gatekeeper | Distinct physical supported Mac, clean user, no development certificate/cached ticket, offline first launch | `not-run` | `<final hash>` | `<reference>` |

## Documentation and support preview review

| Preview or scope | Status | Candidate commit | Sanitized evidence reference | Observation |
|---|---|---|---|---|
| Rendered English README | `not-run` | `<commit>` | `<reference>` | Not reviewed. |
| Rendered Chinese README | `not-run` | `<commit>` | `<reference>` | Not reviewed. |
| Rendered Privacy document | `not-run` | `<commit>` | `<reference>` | Not reviewed. |
| Privacy/security/docs/link/Markdown validators | `not-run` | `<commit>` | `<reference>` | Not reviewed. |
| Known issues and support/non-goal scope | `not-run` | `<commit>` | `<reference>` | Not reviewed. |

## 3. Outstanding external approvals

This section reports authority boundaries; it does not grant authority. An
earlier approval is historical evidence only for the exact action it covered.
Every future action still requires a new one-time, artifact-scoped user
approval immediately before that action.

| External action | Packet disposition | Required separate scope |
|---|---|---|
| Create and first-push a private GitHub repository | `NOT AUTHORIZED BY THIS PACKET` | Owner, repository, private visibility, branch, exact commit, Actions permission, and CI-retention choice. |
| Upload to Apple for notarization | `NOT AUTHORIZED BY THIS PACKET` | Apple team, exact signed pre-staple DMG SHA-256, candidate commit, and exactly one attempt. A consumed prior approval cannot be reused. |
| Send a beta DMG to another person | `NOT AUTHORIZED BY THIS PACKET` | Recipient, transfer channel, exact final SHA-256, and notarization state. Second-Mac evidence never implies this approval. |
| Change the GitHub repository to public | `NOT AUTHORIZED BY THIS PACKET` | Repository and exact reviewed commit. |
| Publish a GitHub Release and DMG | `NOT AUTHORIZED BY THIS PACKET` | Tag/commit, final release text, immutable final stapled DMG SHA-256, `SHA256SUMS`, and verified source archives. |

## Privacy and redaction review

Reject or redact evidence containing any of the following:

- a home path, login name, machine name, serial number, hardware UUID, or
  temporary absolute path;
- a credential, Keychain/notary profile name, API key, authorization header,
  password, or private key;
- transcript text, audio, prompt/instructions, clipboard payload, target-window
  title, or raw platform error;
- provider URL path/query, request/response body, or unsanitized redirect; or
- signing certificate body or private certificate material.

Permitted identifiers are fixed release metadata, coarse Apple Silicon model
class, supported macOS version, safe reviewer label, normalized provider host
when required, sanitized stable error/gate code, commit/tree hashes, artifact
hashes, and owner-approved repository scope.

## Reviewer acknowledgement

| Field | Value |
|---|---|
| Evidence reviewer | `<reviewer label>` |
| Review timestamp | `<RFC 3339 UTC timestamp>` |
| Computed status observed | `NOT_RELEASE_READY` or `READY` |
| Missing/failed gate list reviewed | `yes` or `no` |
| Passed-gate list reviewed | `yes` or `no` |
| Outstanding external approvals reviewed | `yes` or `no` |

Reviewer acknowledgement means only that the evidence packet was inspected.
It is not a beta-transfer, public-transition, push, notarization, or publication
approval. The specific external action must remain stopped until its separate
approval is requested against the exact artifacts immediately before execution.
