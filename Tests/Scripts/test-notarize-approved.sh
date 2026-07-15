#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")/../.." && /bin/pwd -P)"
WRAPPER="$ROOT/Scripts/release/notarize-approved.sh"

/usr/bin/python3 -I - "$WRAPPER" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import textwrap


WRAPPER = Path(os.sys.argv[1])
PROFILE = "utterink-local-notary"
TEAM = "ABCDE12345"
REQUEST_ID = "ab" * 32
SUBMISSION_ID = "12345678-1234-4234-8234-123456789abc"
NOW = "2026-07-15T00:10:00Z"
APPROVED = "2026-07-15T00:00:00Z"
EXPIRES = "2026-07-15T00:30:00Z"


def abort(message: str) -> None:
    raise AssertionError(message)


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_bytes(path: Path, value: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(value)
    path.chmod(mode)


def write_executable(path: Path, value: str) -> None:
    write_bytes(path, textwrap.dedent(value).lstrip().encode(), 0o700)


PREPARE_HELPER = r'''
#!/usr/bin/python3
import hashlib,json,sys
def unique(pairs):
    result={}
    for key,value in pairs:
        if key in result: raise ValueError
        result[key]=value
    return result
def load(path):
    raw=open(path,"rb").read(); value=json.loads(raw.decode(),object_pairs_hook=unique)
    if raw!=(json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(",",":"))+"\n").encode(): raise ValueError
    return raw,value
try:
    if len(sys.argv)!=6 or sys.argv[1]!="validate-approval" or sys.argv[2]!="--request" or sys.argv[4]!="--approval": raise ValueError
    request_raw,request=load(sys.argv[3]); approval_raw,approval=load(sys.argv[5])
    if set(request)!={"schemaVersion","requestType","requestID","product","candidateCommit","candidateTree","appleTeamID","profileBindingReceiptSHA256","preStapleDMG","signatureVerification","attempt","statement"}: raise ValueError
    if set(approval)!={"action","requestID","product","appleTeamID","preStapleDMGSHA256","candidateCommit","profileBindingReceiptSHA256","attempt","approvedAt","expiresAt"}: raise ValueError
    if request["schemaVersion"]!=1 or request["requestType"]!="apple-notarization-request" or request["product"]!="UtterInk" or request["attempt"]!=1: raise ValueError
    if request["statement"]!="one upload attempt only; rejection or any file change requires new approval.": raise ValueError
    if set(request["preStapleDMG"])!={"filename","sizeBytes","sha256"} or set(request["signatureVerification"])!={"evidenceSHA256","status","teamID"}: raise ValueError
    if approval["action"]!="apple-notarization-upload" or approval["product"]!="UtterInk": raise ValueError
    links=(("requestID","requestID"),("appleTeamID","appleTeamID"),("candidateCommit","candidateCommit"),("profileBindingReceiptSHA256","profileBindingReceiptSHA256"),("attempt","attempt"))
    if any(approval[a]!=request[r] for a,r in links): raise ValueError
    if approval["preStapleDMGSHA256"]!=request["preStapleDMG"]["sha256"]: raise ValueError
    print(hashlib.sha256(approval_raw).hexdigest())
except Exception:
    raise SystemExit(1)
'''


PROFILE_HELPER = r'''
#!/bin/bash
set -euo pipefail
[[ "$#" -eq 8 && "$1" == --team-id && "$3" == --keychain-profile && "$5" == --receipt && "$7" == --expected-receipt-sha256 ]] || exit 2
TEAM="$2" PROFILE="$4" RECEIPT="$6" EXPECTED="$8"
/usr/bin/python3 -I - "$TEAM" "$PROFILE" "$RECEIPT" "$EXPECTED" <<'PY_HELPER'
import hashlib,json,sys
team,profile,path,expected=sys.argv[1:]
try:
    raw=open(path,"rb").read(); value=json.loads(raw)
    if hashlib.sha256(raw).hexdigest()!=expected or value["appleTeamID"]!=team: raise ValueError
    actual=hashlib.sha256(b"UtterInk-notary-profile-v1\0"+bytes.fromhex(value["profileNameSalt"])+profile.encode()).hexdigest()
    if actual!=value["profileNameHashSHA256"]: raise ValueError
except Exception: raise SystemExit(1)
PY_HELPER
"${UTTERINK_RELEASE_TEST_TOOL_ROOT}/xcrun" notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null
'''


RESULT_HELPER = r'''
#!/usr/bin/python3
import json,os,sys
try:
    if len(sys.argv)!=9 or sys.argv[1]!="--submission" or sys.argv[3]!="--log" or sys.argv[5]!="--expected-dmg-sha256" or sys.argv[7]!="--output": raise ValueError
    submission=json.load(open(sys.argv[2])); log=json.load(open(sys.argv[4])); expected=sys.argv[6]
    if set(submission)!={"id","message","status"} or submission.get("status")!="Accepted": raise ValueError
    if set(log)!={"archiveFilename","issues","jobId","logFormatVersion","sha256","status","statusCode","statusSummary","ticketContents","uploadDate"}: raise ValueError
    if log.get("status")!="Accepted" or log.get("jobId")!=submission.get("id") or log.get("sha256")!=expected or log.get("statusCode")!=0: raise ValueError
    issues=log.get("issues")
    if type(issues) is not list or any(type(x) is not dict or x.get("severity") in {"error","invalid"} for x in issues): raise ValueError
    warnings=[x for x in issues if x.get("severity")=="warning"]
    output={"automaticRetry":False,"completeLogReviewed":True,"dmgSHA256":expected,"evidenceType":"notarization-result-review","logStatusSummary":log["statusSummary"],"product":"UtterInk","schemaVersion":1,"status":"Accepted","submissionID":submission["id"],"warningCount":len(warnings),"warnings":warnings}
    raw=(json.dumps(output,sort_keys=True,separators=(",",":"))+"\n").encode()
    fd=os.open(sys.argv[8],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(fd,raw); os.close(fd)
    os.write(1,raw)
except Exception: raise SystemExit(1)
'''


INSPECT_HELPER = r'''
#!/bin/bash
set -euo pipefail
[[ "$#" -eq 4 && "$1" == --dmg && "$3" == --mode && "$4" == signed ]] || exit 2
printf 'inspect\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${UTTERINK_RELEASE_TEST_LOG}"
/usr/bin/grep -q 'stapled-ticket' "$2" || exit 1
HASH="$(/usr/bin/shasum -a 256 "$2" | /usr/bin/awk '{print $1}')"
printf '{"dmgSHA256":"%s","mode":"signed","signature":"developer-id","status":"valid"}\n' "$HASH"
'''


XCRUN = rf'''
#!/bin/bash
set -euo pipefail
LOG="${{UTTERINK_RELEASE_TEST_LOG:?}}"
line=xcrun
for value in "$@"; do
  line="${{line}}"$'\t'"$value"
done
/usr/bin/printf '%s\n' "$line" >> "$LOG"
if [[ "$1" == notarytool && "$2" == history ]]; then
  APPROVAL="$(/bin/cat "$LOG.approval")"
  [[ -f "$APPROVAL" && ! -L "$APPROVAL" ]] || exit 88
  [[ "${{UTTERINK_RELEASE_TEST_SCENARIO:-accepted}}" != history-failure ]] || exit 96
  /usr/bin/printf '{{"history":[]}}\n'
elif [[ "$1" == notarytool && "$2" == submit ]]; then
  APPROVAL="$(/bin/cat "$LOG.approval")"
  [[ ! -e "$APPROVAL" && ! -L "$APPROVAL" ]] || exit 89
  /usr/bin/printf '%s\n' "$3" > "$LOG.dmg"
  case "${{UTTERINK_RELEASE_TEST_SCENARIO:-accepted}}" in
    crash) exit 97 ;;
    rejected) /usr/bin/printf '{{"id":"{SUBMISSION_ID}","message":"invalid","status":"Invalid"}}\n' ;;
    *) /usr/bin/printf '{{"id":"{SUBMISSION_ID}","message":"approved","status":"Accepted"}}\n' ;;
  esac
elif [[ "$1" == notarytool && "$2" == log ]]; then
  DMG="$(/bin/cat "$LOG.dmg")"
  HASH="$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{{print $1}}')"
  if [[ "${{UTTERINK_RELEASE_TEST_SCENARIO:-accepted}}" == invalid-log ]]; then
    /usr/bin/printf '{{"archiveFilename":"UtterInk-0.1.0-arm64.dmg","issues":[{{"message":"bad","severity":"error"}}],"jobId":"{SUBMISSION_ID}","logFormatVersion":1,"sha256":"%s","status":"Accepted","statusCode":0,"statusSummary":"Ready for distribution","ticketContents":[{{"digestAlgorithm":"SHA-256","path":"UtterInk.app"}}],"uploadDate":"2026-07-15T00:11:00Z"}}\n' "$HASH"
  else
    /usr/bin/printf '{{"archiveFilename":"UtterInk-0.1.0-arm64.dmg","issues":[{{"message":"review","severity":"warning"}}],"jobId":"{SUBMISSION_ID}","logFormatVersion":1,"sha256":"%s","status":"Accepted","statusCode":0,"statusSummary":"Ready for distribution","ticketContents":[{{"digestAlgorithm":"SHA-256","path":"UtterInk.app"}}],"uploadDate":"2026-07-15T00:11:00Z"}}\n' "$HASH"
  fi
elif [[ "$1" == stapler && "$2" == staple ]]; then
  /usr/bin/printf 'stapled-ticket\n' >> "$3"
elif [[ "$1" == stapler && "$2" == validate ]]; then
  /usr/bin/grep -q 'stapled-ticket' "$3"
else
  exit 64
fi
'''


SHASUM = r'''
#!/bin/bash
set -euo pipefail
line=shasum
for value in "$@"; do line="${line}"$'\t'"$value"; done
printf '%s\n' "$line" >> "${UTTERINK_RELEASE_TEST_LOG}"
exec /usr/bin/shasum "$@"
'''


DATE = rf'''
#!/bin/bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == -u && "$2" == +%Y-%m-%dT%H:%M:%SZ ]] || exit 2
STATE="${{UTTERINK_RELEASE_TEST_LOG}}.date-count"
COUNT=0
if [[ -f "$STATE" ]]; then COUNT="$(/bin/cat "$STATE")"; fi
COUNT=$((COUNT + 1))
/usr/bin/printf '%s\n' "$COUNT" > "$STATE"
if [[ "${{UTTERINK_RELEASE_TEST_SCENARIO:-accepted}}" == expires-after-history && "$COUNT" -ge 2 ]] || \
   [[ "${{UTTERINK_RELEASE_TEST_SCENARIO:-accepted}}" == expires-at-consumption && "$COUNT" -ge 3 ]]; then
  printf '%s\n' '2026-07-15T00:31:00Z'
else
  printf '%s\n' '{NOW}'
fi
'''


class Fixture:
    def __init__(self, scenario: str = "accepted") -> None:
        if not WRAPPER.is_file():
            abort("guarded notarization wrapper is missing")
        self.temp = tempfile.TemporaryDirectory(prefix="utterink-notarize-approved.", dir="/private/tmp")
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.wrapper = self.root / "Scripts/release/notarize-approved.sh"
        self.prepare = self.root / "Scripts/release/prepare-notarization-request.py"
        self.profile_helper = self.root / "Scripts/release/verify-notary-profile-binding.sh"
        self.result_helper = self.root / "Scripts/release/verify-notarization-result.py"
        self.inspect = self.root / "Scripts/inspect-dmg.sh"
        self.tools = self.root / "FixtureTools"
        self.tools.mkdir(mode=0o700)
        self.log = self.root / "tool-calls.log"
        self.scenario = scenario
        self.wrapper.parent.mkdir(parents=True, mode=0o700)
        shutil.copyfile(WRAPPER, self.wrapper)
        self.wrapper.chmod(0o700)
        write_executable(self.prepare, PREPARE_HELPER)
        write_executable(self.profile_helper, PROFILE_HELPER)
        write_executable(self.result_helper, RESULT_HELPER)
        write_executable(self.inspect, INSPECT_HELPER)
        write_executable(self.tools / "xcrun", XCRUN)
        write_executable(self.tools / "shasum", SHASUM)
        write_executable(self.tools / "date", DATE)
        write_bytes(self.tools / ".utterink-notarization-test-tools", b"utterink-notarization-test-tools-v1\n", 0o600)
        write_bytes(self.root / ".utterink-notarization-test-repository", b"utterink-notarization-test-repository-v1\n", 0o600)
        for relative in (
            "Config/release-metadata.json",
            "Config/release-info-policy.json",
            "Config/release-entitlements.plist",
            "Config/dmg-allowed-content.txt",
            "Scripts/release/read-metadata.py",
            "Scripts/release/verify-info-policy.py",
        ):
            write_bytes(self.root / relative, b"fixture-policy\n", 0o600)
        subprocess.run(["/usr/bin/git", "init", "-q", str(self.root)], check=True)
        subprocess.run([
            "/usr/bin/git", "-C", str(self.root), "-c", "user.name=UtterInk Test",
            "-c", "user.email=utterink-test@example.invalid", "-c", "commit.gpgsign=false",
            "add", "Scripts", "Config",
        ], check=True)
        subprocess.run([
            "/usr/bin/git", "-C", str(self.root), "-c", "user.name=UtterInk Test",
            "-c", "user.email=utterink-test@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-qm", "fixture",
        ], check=True)
        self.commit = subprocess.check_output(["/usr/bin/git", "-C", str(self.root), "rev-parse", "HEAD"], text=True).strip()
        self.tree = subprocess.check_output(["/usr/bin/git", "-C", str(self.root), "rev-parse", "HEAD^{tree}"], text=True).strip()
        self.dmg = self.root / ".release-work/candidate/UtterInk-0.1.0-arm64.dmg"
        write_bytes(self.dmg, b"UtterInk signed DMG fixture\n", 0o600)
        self.pre_hash = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        salt = "34" * 32
        profile_hash = hashlib.sha256(b"UtterInk-notary-profile-v1\0" + bytes.fromhex(salt) + PROFILE.encode()).hexdigest()
        receipt_without_self = {
            "appleTeamID": TEAM,
            "bindingNonce": "56" * 32,
            "expiresAt": "2026-07-16T00:00:00Z",
            "notarytoolVersion": "notarytool 1.0",
            "profileNameHashSHA256": profile_hash,
            "profileNameSalt": salt,
            "schemaVersion": 1,
            "signingCertificateSHA256": "78" * 32,
            "validatedAt": "2026-07-15T00:00:00Z",
        }
        self_hash = hashlib.sha256(canonical(receipt_without_self)).hexdigest()
        self.receipt = self.root / ".notary-profile-bindings/random-binding.json"
        write_bytes(self.receipt, canonical({**receipt_without_self, "selfSHA256": self_hash}), 0o600)
        self.receipt_hash = hashlib.sha256(self.receipt.read_bytes()).hexdigest()
        self.request_data = {
            "appleTeamID": TEAM,
            "attempt": 1,
            "candidateCommit": self.commit,
            "candidateTree": self.tree,
            "preStapleDMG": {"filename": self.dmg.name, "sha256": self.pre_hash, "sizeBytes": self.dmg.stat().st_size},
            "product": "UtterInk",
            "profileBindingReceiptSHA256": self.receipt_hash,
            "requestID": REQUEST_ID,
            "requestType": "apple-notarization-request",
            "schemaVersion": 1,
            "signatureVerification": {"evidenceSHA256": "9a" * 32, "status": "valid", "teamID": TEAM},
            "statement": "one upload attempt only; rejection or any file change requires new approval.",
        }
        self.request = self.root / ".release-requests/unpredictable-request.json"
        write_bytes(self.request, canonical(self.request_data), 0o400)
        self.approval_data = {
            "action": "apple-notarization-upload",
            "appleTeamID": TEAM,
            "approvedAt": APPROVED,
            "attempt": 1,
            "candidateCommit": self.commit,
            "expiresAt": EXPIRES,
            "preStapleDMGSHA256": self.pre_hash,
            "product": "UtterInk",
            "profileBindingReceiptSHA256": self.receipt_hash,
            "requestID": REQUEST_ID,
        }
        self.approval = self.root / ".release-approvals/reviewed-approval.json"
        self.write_approval()
        write_bytes(Path(str(self.log) + ".approval"), (str(self.approval) + "\n").encode(), 0o600)

    def write_approval(self) -> None:
        write_bytes(self.approval, canonical(self.approval_data), 0o600)

    def invocation(self, *, approval: Path | None = None, profile: str = PROFILE, test_mode: bool = True, path: str = "/evil") -> tuple[list[str], dict[str, str]]:
        target = self.approval if approval is None else approval
        environment = {"PATH": path, "LC_ALL": "C"}
        if test_mode:
            environment.update({
                "UTTERINK_RELEASE_TEST_MODE": "1",
                "UTTERINK_RELEASE_TEST_TOOL_ROOT": str(self.tools),
                "UTTERINK_RELEASE_TEST_SCENARIO": self.scenario,
                "UTTERINK_RELEASE_TEST_LOG": str(self.log),
            })
        command = [
            str(self.wrapper), "--dmg", str(self.dmg), "--approval", str(target),
            "--keychain-profile", profile,
        ]
        return command, environment

    def run(self, *, approval: Path | None = None, profile: str = PROFILE, test_mode: bool = True, path: str = "/evil") -> subprocess.CompletedProcess[str]:
        command, environment = self.invocation(approval=approval, profile=profile, test_mode=test_mode, path=path)
        return subprocess.run(command, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)

    def start(self) -> subprocess.Popen[str]:
        command, environment = self.invocation()
        return subprocess.Popen(command, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def commands(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [line.split("\t") for line in self.log.read_text().splitlines() if line]

    def xcrun_commands(self) -> list[list[str]]:
        return [command[1:] for command in self.commands() if command[0] == "xcrun"]

    def close(self) -> None:
        self.temp.cleanup()


def rejected_before_xcrun(name: str, mutate) -> None:
    fixture = Fixture()
    try:
        mutate(fixture)
        approval_should_remain = os.path.lexists(fixture.approval)
        result = fixture.run()
        if result.returncode == 0: abort(f"{name}: expected rejection")
        if fixture.xcrun_commands(): abort(f"{name}: invoked xcrun")
        if approval_should_remain and not os.path.lexists(fixture.approval): abort(f"{name}: consumed approval before local validation")
    finally:
        fixture.close()


def assert_consumed_file(fixture: Fixture, original: bytes) -> Path:
    approval_hash = hashlib.sha256(original).hexdigest()
    consumed = fixture.root / ".release-approvals/consumed" / f"{REQUEST_ID}-{approval_hash}.json"
    if not consumed.is_file() or consumed.is_symlink(): abort("consumed approval record is missing or unsafe")
    item = consumed.stat()
    if stat.S_IMODE(item.st_mode) != 0o600 or item.st_nlink != 1: abort("consumed approval record mode/link count is wrong")
    if consumed.read_bytes() != original or hashlib.sha256(consumed.read_bytes()).hexdigest() != approval_hash: abort("consumed approval bytes/hash changed")
    return consumed


def assert_consumed(fixture: Fixture, original: bytes) -> None:
    assert_consumed_file(fixture, original)
    approval_hash = hashlib.sha256(original).hexdigest()
    record_path = fixture.root / ".release-evidence/notarization" / REQUEST_ID / "approval-consumed.json"
    expected = {"approvalSHA256": approval_hash, "attempt": 1, "requestID": REQUEST_ID, "status": "consumed"}
    if json.loads(record_path.read_text()) != expected or stat.S_IMODE(record_path.stat().st_mode) != 0o600: abort("consumption evidence is invalid")


rejected_before_xcrun("no approval", lambda f: f.approval.unlink())
rejected_before_xcrun("changed DMG", lambda f: f.dmg.write_bytes(f.dmg.read_bytes() + b"x"))


def wrong_team(f: Fixture) -> None:
    f.approval_data["appleTeamID"] = "ZZZZZ99999"
    f.write_approval()


def wrong_commit(f: Fixture) -> None:
    f.approval_data["candidateCommit"] = "0" * 40
    f.write_approval()


def expired(f: Fixture) -> None:
    f.approval_data["approvedAt"] = "2026-07-14T23:00:00Z"
    f.approval_data["expiresAt"] = "2026-07-14T23:30:00Z"
    f.write_approval()


def request_head_mismatch(f: Fixture) -> None:
    wrong = "3" * 40
    f.request_data["candidateCommit"] = wrong
    f.approval_data["candidateCommit"] = wrong
    f.request.chmod(0o600)
    write_bytes(f.request, canonical(f.request_data), 0o400)
    f.write_approval()


def unsafe_approval_mode(f: Fixture) -> None:
    f.approval.chmod(0o644)


def symlink_approval(f: Fixture) -> None:
    target = f.approval.with_name("approval-target.json")
    f.approval.rename(target)
    f.approval.symlink_to(target.name)


def helper_mismatch(f: Fixture) -> None:
    with f.result_helper.open("ab") as handle:
        handle.write(b"\n")


def receipt_expires_before_approval(f: Fixture) -> None:
    receipt = json.loads(f.receipt.read_text())
    receipt["validatedAt"] = "2026-07-14T00:20:00Z"
    receipt["expiresAt"] = "2026-07-15T00:20:00Z"
    without_self = dict(receipt)
    without_self.pop("selfSHA256")
    receipt["selfSHA256"] = hashlib.sha256(canonical(without_self)).hexdigest()
    write_bytes(f.receipt, canonical(receipt), 0o600)
    receipt_hash = hashlib.sha256(f.receipt.read_bytes()).hexdigest()
    f.request_data["profileBindingReceiptSHA256"] = receipt_hash
    f.approval_data["profileBindingReceiptSHA256"] = receipt_hash
    f.request.chmod(0o600)
    write_bytes(f.request, canonical(f.request_data), 0o400)
    f.write_approval()


rejected_before_xcrun("wrong Team ID", wrong_team)
rejected_before_xcrun("wrong commit", wrong_commit)
rejected_before_xcrun("request commit not HEAD", request_head_mismatch)
rejected_before_xcrun("expired approval", expired)
rejected_before_xcrun("world-readable approval", unsafe_approval_mode)
rejected_before_xcrun("symlink approval", symlink_approval)
rejected_before_xcrun("helper blob mismatch", helper_mismatch)
rejected_before_xcrun("approval outlives profile receipt", receipt_expires_before_approval)

fixture = Fixture()
try:
    result = fixture.run(profile="different-local-profile")
    if result.returncode == 0: abort("wrong profile unexpectedly succeeded")
    if fixture.xcrun_commands(): abort("wrong profile invoked xcrun")
    if not fixture.approval.exists(): abort("wrong profile consumed approval")
finally:
    fixture.close()

fixture = Fixture("history-failure")
try:
    result = fixture.run()
    if result.returncode == 0: abort("profile history failure unexpectedly succeeded")
    if not fixture.approval.exists(): abort("profile history failure consumed approval")
    if any(command[:2] == ["notarytool", "submit"] for command in fixture.xcrun_commands()): abort("profile history failure submitted DMG")
    if [command[:2] for command in fixture.xcrun_commands()] != [["notarytool", "history"]]: abort("profile history failure Apple command shape is wrong")
finally:
    fixture.close()

fixture = Fixture("expires-after-history")
try:
    result = fixture.run()
    if result.returncode == 0: abort("approval that expired during profile verification succeeded")
    if not fixture.approval.exists(): abort("approval that expired during profile verification was consumed")
    if [command[:2] for command in fixture.xcrun_commands()] != [["notarytool", "history"]]: abort("expiry crossing reached submit or wrong Apple command")
finally:
    fixture.close()

fixture = Fixture("expires-at-consumption")
try:
    result = fixture.run()
    if result.returncode == 0: abort("approval that expired at atomic consumption succeeded")
    if not fixture.approval.exists(): abort("approval that expired at atomic consumption was consumed")
    if [command[:2] for command in fixture.xcrun_commands()] != [["notarytool", "history"]]: abort("atomic expiry crossing reached submit or wrong Apple command")
finally:
    fixture.close()

fixture = Fixture("crash-before-consume")
try:
    original_approval = fixture.approval.read_bytes()
    result = fixture.run()
    if result.returncode == 0: abort("pre-consumption crash unexpectedly succeeded")
    work = fixture.root / ".release-evidence/notarization" / REQUEST_ID
    if not fixture.approval.exists() or os.path.lexists(work): abort("pre-consumption crash stranded approval behind final work reservation")
    if any(command[:2] == ["notarytool", "submit"] for command in fixture.xcrun_commands()): abort("pre-consumption crash submitted DMG")
    fixture.scenario = "accepted"
    recovered = fixture.run()
    if recovered.returncode != 0: abort(f"approval did not recover after pre-consumption crash: {recovered.stderr}")
    if len([command for command in fixture.xcrun_commands() if command[:2] == ["notarytool", "submit"]]) != 1: abort("recovered approval did not submit exactly once")
    assert_consumed(fixture, original_approval)
finally:
    fixture.close()

fixture = Fixture("crash-after-consume")
try:
    original_approval = fixture.approval.read_bytes()
    result = fixture.run()
    if result.returncode == 0: abort("post-consumption crash unexpectedly succeeded")
    work = fixture.root / ".release-evidence/notarization" / REQUEST_ID
    if fixture.approval.exists() or os.path.lexists(work): abort("post-consumption crash restored approval or created final work reservation")
    assert_consumed_file(fixture, original_approval)
    first_count = len(fixture.xcrun_commands())
    reused = fixture.run()
    if reused.returncode == 0 or len(fixture.xcrun_commands()) != first_count: abort("post-consumption crash allowed replay")
finally:
    fixture.close()

fixture = Fixture("rejected")
try:
    original_approval = fixture.approval.read_bytes()
    result = fixture.run()
    if result.returncode == 0: abort("rejected result unexpectedly succeeded")
    submit = [c for c in fixture.xcrun_commands() if c[:2] == ["notarytool", "submit"]]
    if len(submit) != 1: abort(f"rejected result retried or skipped submit: stderr={result.stderr!r}, commands={fixture.commands()!r}")
    if any(c[0] == "stapler" for c in fixture.xcrun_commands()): abort("rejected result invoked stapler")
    if fixture.approval.exists() or fixture.approval.is_symlink(): abort("rejected result restored approval")
    if not (fixture.root / ".release-evidence/notarization" / REQUEST_ID / "attempt-invoked").is_file(): abort("rejected result lost invocation marker")
    assert_consumed(fixture, original_approval)
finally:
    fixture.close()

fixture = Fixture("crash")
try:
    original_approval = fixture.approval.read_bytes()
    result = fixture.run()
    if result.returncode == 0: abort("crashed submit unexpectedly succeeded")
    if fixture.approval.exists() or fixture.approval.is_symlink(): abort("crash restored consumed approval")
    if len([c for c in fixture.xcrun_commands() if c[:2] == ["notarytool", "submit"]]) != 1: abort("crash submit count is not one")
    if not (fixture.root / ".release-evidence/notarization" / REQUEST_ID / "attempt-invoked").is_file(): abort("crash lost invocation marker")
    assert_consumed(fixture, original_approval)
finally:
    fixture.close()

fixture = Fixture("invalid-log")
try:
    result = fixture.run()
    if result.returncode == 0: abort("invalid Apple log unexpectedly succeeded")
    if any(c[0] == "stapler" for c in fixture.xcrun_commands()): abort("invalid Apple log invoked stapler")
finally:
    fixture.close()

fixture = Fixture("accepted")
try:
    reusable_copy = fixture.approval.read_bytes()
    prestaple_copy = fixture.dmg.read_bytes()
    result = fixture.run()
    if result.returncode != 0: abort(f"valid approval failed: {result.stderr}")
    commands = fixture.xcrun_commands()
    submit = [c for c in commands if c[:2] == ["notarytool", "submit"]]
    expected_submit = [
        "notarytool", "submit", str(fixture.dmg), "--keychain-profile", PROFILE,
        "--wait", "--timeout", "30m", "--output-format", "json",
    ]
    if submit != [expected_submit]: abort(f"submit shape mismatch: {submit!r}")
    expected_prefixes = [
        ["notarytool", "history"], ["notarytool", "submit"], ["notarytool", "log"],
        ["stapler", "staple"], ["stapler", "validate"],
    ]
    if [c[:2] for c in commands] != expected_prefixes: abort(f"Apple command order mismatch: {commands!r}")
    work = fixture.root / ".release-evidence/notarization" / REQUEST_ID
    expected_files = {
        "submission.json", "notary-log.json", "notarization-result.json",
        "post-staple.sha256", "inspection.json", "attempt-invoked",
    }
    if not expected_files.issubset({p.name for p in work.iterdir()}): abort("notarization evidence is incomplete")
    if stat.S_IMODE(work.stat().st_mode) != 0o700: abort("evidence directory is not owner-only")
    for item in work.iterdir():
        if not item.is_file() or item.is_symlink(): abort(f"unsafe evidence item: {item.name}")
        if stat.S_IMODE(item.stat().st_mode) & 0o077: abort(f"evidence {item.name} is not owner-only")
        if PROFILE.encode() in item.read_bytes(): abort(f"profile name leaked into {item.name}")
    post_hash = (work / "post-staple.sha256").read_text().strip()
    if post_hash == fixture.pre_hash or post_hash != hashlib.sha256(fixture.dmg.read_bytes()).hexdigest(): abort("post-staple hash is wrong")
    assert_consumed(fixture, reusable_copy)
    first_count = len(fixture.xcrun_commands())
    write_bytes(fixture.dmg, prestaple_copy, 0o600)
    write_bytes(fixture.approval, reusable_copy, 0o600)
    reused = fixture.run()
    if reused.returncode == 0: abort("consumed approval was reusable")
    if len(fixture.xcrun_commands()) != first_count: abort("reused approval invoked xcrun")
finally:
    fixture.close()

fixture = Fixture("accepted")
try:
    original_approval = fixture.approval.read_bytes()
    first = fixture.start()
    second = fixture.start()
    first_output = first.communicate(timeout=20)
    second_output = second.communicate(timeout=20)
    del first_output, second_output
    if sorted([first.returncode, second.returncode]).count(0) != 1: abort("concurrent approval race did not produce exactly one winner")
    submit = [command for command in fixture.xcrun_commands() if command[:2] == ["notarytool", "submit"]]
    if len(submit) != 1: abort("concurrent approval race submitted other than exactly once")
    assert_consumed(fixture, original_approval)
finally:
    fixture.close()

fixture = Fixture()
try:
    malicious = fixture.root / "MaliciousPath"
    malicious.mkdir(mode=0o700)
    marker = fixture.root / "malicious-xcrun-used"
    write_executable(malicious / "xcrun", f"#!/bin/bash\n: > '{marker}'\nexit 99\n")
    fixture.approval.unlink()
    result = fixture.run(test_mode=False, path=str(malicious))
    if result.returncode == 0: abort("production-mode missing approval unexpectedly succeeded")
    if marker.exists(): abort("production mode honored caller PATH")
finally:
    fixture.close()

print("PASS: guarded notarization wrapper is offline, one-use, exact, and ordered")
PY
