# UtterInk Security Policy

## Supported versions

Security fixes are prepared for the current `main` development line and, once
a release exists, the latest published release. Older releases, development
snapshots, modified builds, and third-party forks are not maintained by the
UtterInk project.

| Version | Security support |
| --- | --- |
| Current `main` development line | Supported |
| Latest published release, when available | Supported |
| Older releases, snapshots, modified builds, and forks | Not supported |

## Reporting a vulnerability

Report suspected vulnerabilities privately by email to
<swallowclever.k3@gmail.com>. Do not open a public issue, discussion, or pull
request for an unpatched vulnerability or include sensitive evidence in a
public channel.

Please include the affected UtterInk version or commit, macOS version, impact,
reproduction conditions, and the smallest sanitized proof needed to understand
the report. Do not send working credentials, private keys, raw dictation audio,
transcripts, or unrelated personal data.

## What happens after a report

The maintainer will receive and triage the report, determine the affected
surface and versions, and coordinate investigation and a fix with the reporter
and any affected dependency maintainer. When a fix is ready, the maintainer and
reporter will coordinate the timing and content of disclosure so users can
update before exploit details are made public. Reports that do not describe a
security issue may be redirected to the ordinary issue tracker.

Response time depends on severity, reproducibility, maintainer availability,
and upstream coordination. This project does not promise a fixed response or
resolution SLA.

## Credentials and sensitive data

- UtterInk does not bundle provider API keys. Users supply optional provider
  credentials, which the app stores in macOS Keychain rather than plaintext
  project files or logs.
- Never commit, attach, or paste API keys, access tokens, passwords, private
  keys, signing material, Keychain exports, raw audio, or private transcripts
  into an issue, discussion, pull request, test fixture, or diagnostic report.
- Redact diagnostics to the minimum data needed to reproduce the problem. The
  maintainer will not ask for a password or a complete credential.
- If a credential may have been exposed, revoke or rotate it with its provider
  before continuing the report. Email is a reporting channel, not a secret
  vault, so do not send the live credential to the project.

## Dependency vulnerabilities

Report a suspected vulnerability in a shipped or runtime-downloaded dependency
through the same private channel. Include the dependency name, resolved version
or immutable revision, relevant advisory identifier if one exists, and the
UtterInk impact. The maintainer will validate reachability, coordinate with the
upstream project when appropriate, update or mitigate the dependency, and
include attribution in a coordinated disclosure without publishing sensitive
details prematurely.

Public issues are appropriate only after disclosure has been coordinated or
when the report contains no sensitive details and concerns general hardening.
