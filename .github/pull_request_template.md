## Summary

<!-- What changed, why, and what is intentionally out of scope? -->

## Related issue or design discussion

<!-- Link the approved issue/design discussion for behavior changes. For a non-behavioral change, explain why prior discussion is not applicable. -->

## Platform verification

- macOS version and build:
- UtterInk commit/build tested:
- Architecture: Apple Silicon / arm64

## Behavior verification

### Reproduction before this change

<!-- Give sanitized, deterministic steps. Write "Not applicable" with a reason when this is not a bug fix. -->

### Expected behavior

<!-- State the observable expected result. -->

### Actual behavior after this change

<!-- State the verified result and any remaining limitation. -->

## Test evidence

<!-- Record the intended failing test first, then exact focused commands, complete verification, and privacy-safe manual scenarios with results. -->

- [ ] Tests were added or updated before/with the implementation, or the reason tests are not applicable is explained above.
- [ ] Relevant focused tests pass.
- [ ] `./Scripts/ci-local.sh` passes.

## Privacy and security

<!-- Describe effects on transient audio, local History, provider text egress, Keychain credentials, model downloads/cache, pasteboard handling, diagnostics, permissions, and deletion. Write "No impact" when appropriate. Never paste sensitive evidence here. -->

- [ ] Test fixtures are synthetic and contain no real credentials, transcripts, audio, pasteboard contents, private paths, or unrelated personal data.
- [ ] Logging and diagnostics remain restricted to allowlisted, sanitized fields.
- [ ] Any sensitive vulnerability was reported privately under the repository-root `SECURITY.md` instructions, not disclosed in this pull request.

## Accessibility

<!-- Describe keyboard traversal/focus return, VoiceOver name/role/value/actions, non-color status, contrast, motion, larger text, permission, target-validation, and Automatic Paste impact. Include checks performed, or explain why there is no impact. -->

- [ ] Accessibility behavior was reviewed and relevant checks were run.
- [ ] `docs/parity/accessibility-matrix.md` was updated when a covered surface changed, and no unrun manual check is marked passed.

## Dependencies and licensing

<!-- List dependency changes, pinned versions/revisions, distribution role, license, notices, and transitive obligations. Write "Not applicable" when there is no dependency change. -->

- [ ] Dependencies use Swift Package Manager only and `Packages/UtterInkKit/Package.resolved` is updated when required.
- [ ] I reviewed license and notice obligations, confirmed compatibility with Apache-2.0, and included every required attribution, or marked this item not applicable with a reason.

## Deterministic project and assets

<!-- Describe project.yml, generated Xcode project, or Brand source/lock changes and the deterministic checks run. -->

- [ ] XcodeGen and identity outputs were regenerated from authoritative sources and their complete diffs were reviewed, or this is not applicable.

## Documentation and changelog

<!-- List English/Chinese README, privacy, security, contributor, and changelog updates. Explain why no public-document change is needed when applicable. -->

- [ ] User-visible behavior and privacy claims are mirrored in the relevant English and Chinese documentation.
- [ ] `CHANGELOG.md` is updated for a notable change, or the reason it is not needed is stated.

## Sanitized diagnostics

<!-- Optional. Include only reviewed allowlisted output. Do not include transcripts, audio, credentials, prompts, pasteboard contents, private paths, window titles, raw errors, response bodies, or full provider URLs. -->

## Screenshots or recordings

<!-- Optional. Crop and redact media so it contains no transcripts, audio content, credentials, private paths, pasteboard contents, personal window titles, or other private data. State that you have the right to submit it, or write "Not applicable". -->

## Final checklist

- [ ] Behavior changes have a linked issue or design discussion, or a clear non-applicable explanation.
- [ ] The intended failing test and passing evidence are recorded, or a justified non-applicable explanation is provided.
- [ ] Project generation and asset changes are deterministic and reproducible.
- [ ] No signing material, provider credential, or private user content is included in the change or its Git history.
- [ ] I own or am authorized to contribute this material and understand that intentional submissions are provided under Apache-2.0 Section 5 unless explicitly stated otherwise.
