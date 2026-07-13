# ATS loopback policy provenance

## Decision

UtterInk and the signed `ATSPolicyProbe` use no `NSAppTransportSecurity`
dictionary. No ATS exception, arbitrary-load key, exception domain, local-network
usage description, or probe sandbox entitlement was added. The production client
rewrites the approved loopback endpoint to a literal `127.0.0.1` URL before the
request.

The permanent gate accepts only two identical policy shapes across the main app
plist, probe source plist, and built probe plist: no ATS dictionary, or exactly
`{ NSAllowsLocalNetworking = true }`. The verified shape on 2026-07-13 was absent
in all three locations.

## Signed proof

- Baseline parent: `4fe8010d81868f44db85c4ea025621de7953cfa7`.
- RED: `bash Tests/Scripts/test-ats-policy.sh` exited 65 because the generated
  project did not contain the `ATSPolicyProbe` scheme.
- GREEN: the same command generated the project, built the arm64 macOS app with
  `CODE_SIGNING_ALLOWED=YES`, manual signing, `CODE_SIGN_IDENTITY=-`, and an empty
  development team, then exited 0.
- `codesign --verify --strict ATSPolicyProbe.app` exited 0. Xcode reported the
  signing identity as `Sign to Run Locally`.
- The extracted effective entitlements contain no app sandbox, network client,
  or network server entitlement, and all three plists omit
  `NSLocalNetworkUsageDescription`.
- The signed executable printed exactly `ATS_LOOPBACK_PASS`; no explicit ATS
  `-1022` evidence was observed, so no exception was justified or added.

## Fixture and disclosure boundary

The test fixture binds only to `127.0.0.1` on an operating-system-selected port.
It accepts only `GET /v1/models`, rejects any `Authorization` header, and returns
bounded JSON containing only the exact model ID `ats-probe-model`. The probe uses
`OpenAICompatibleClient(clock: SystemAppClock())`, `.loopbackHTTP`, and an empty
`SessionSecret`. It receives no provider key or transcript. Probe stderr is held
inside the owned temporary directory; failure output is reduced to a fixed ATS
`-1022` classification or a fixed generic failure.

All DerivedData, fixture files, and default cloned package state live under a
physically canonicalized unique external temporary root. An optional caller-owned
cloned-source-packages directory is physically resolved before containment checks,
may be reused, and is never deleted by the nested probe.

## Verification environment

- macOS 26.3.1 (a), build 25D771280a, arm64
- Xcode 26.4, build 17E192
- Apple Swift 6.3 (`swiftlang-6.3.0.123.5`)
- XcodeGen 2.45.4
- Reviewer: `kthree0213`
