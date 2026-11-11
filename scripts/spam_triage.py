#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.
"""
Spam issue triage for meta/facebook-ios-sdk.

Deterministic (no LLM). Designed for PRECISION first: a wrongly-closed real bug
is far worse than leaving a spam issue open one more day.

Decision model
--------------
For each OPEN issue we compute:
  * a HARD-HAM veto  -> if any genuine-SDK / maintainer signal is present, never act.
  * a spam score     -> weighted sum of independent spam signals across title+body.

Actions:
  * CLOSE  if a KNOWN scam phone number is present, OR score >= CLOSE_THRESHOLD,
           AND the hard-ham veto did not fire.
  * LABEL  `possible-spam` (no close) if MED <= score < CLOSE_THRESHOLD.
  * SKIP   otherwise, or whenever the veto fires.

Why this is accurate
--------------------
Both observed spam waves embedded a phone number in the body (e.g. 650-543-4800,
+1-844-607-3947) — often obfuscated with unicode / letter-for-digit tricks, and
hidden inside the real bug-report template. Genuine SDK issues contain code,
stack traces, Xcode/SPM details, and version numbers, but ~never a phone number.
So phone-in-body + absence of SDK signals is a very high-precision spam tell, and
the hard-ham veto protects the rare real issue that happens to contain long digit
runs (crash addresses, timestamps) because those carry SDK signals.

Env:
  GH_TOKEN   (required)  token with issues:write  (Actions: ${{ github.token }})
  REPO       (required)  owner/name
  DRY_RUN    "1"/"true"  -> log only, never close/label (default: dry run)
  MAX_CLOSE  int         -> cap closes per run        (default 50)
  MAX_LABEL  int         -> cap labels per run         (default 50)
  TRIPWIRE   int         -> if closeable count exceeds this, ABORT closing and
                           report instead (guards against a bad pattern). default 80
  LOOKBACK_DAYS int      -> only consider issues updated within N days (default 45)
"""

import json
import os
import re
import subprocess
import sys
import unicodedata
from datetime import datetime, timedelta, timezone

REPO = os.environ.get("REPO") or ""
DRY_RUN = (os.environ.get("DRY_RUN", "1").lower() in ("1", "true", "yes"))
MAX_CLOSE = int(os.environ.get("MAX_CLOSE", "50"))
MAX_LABEL = int(os.environ.get("MAX_LABEL", "50"))
TRIPWIRE = int(os.environ.get("TRIPWIRE", "80"))
LOOKBACK_DAYS = int(os.environ.get("LOOKBACK_DAYS", "45"))

CLOSE_THRESHOLD = 90
LABEL_THRESHOLD = 45

# Account-age heuristic (suggested in issue #2864): spam comes from throwaway
# accounts created days ago; long-lived accounts lean legitimate. We only fetch
# the author's age for issues that ALREADY show some spam signal (>= this), to
# bound API calls.
INVESTIGATE_THRESHOLD = 25
VERY_NEW_ACCOUNT_DAYS = 7
NEW_ACCOUNT_DAYS = 30
ESTABLISHED_ACCOUNT_DAYS = 365

SPAM_LABEL = "possible-spam"
# Applied to high-confidence spam that we close, so the closure is clearly
# attributed/auditable (distinct from `possible-spam`, which flags for review).
CONFIRMED_SPAM_LABEL = "spam"

SPAM_COMMENT = """\
Hi! This GitHub repository is for the Facebook iOS SDK (code + bug reports related to the SDK). \
We can't help verify phone numbers, handle account recovery, or provide customer support from this issue tracker.

If you need help with a Facebook/Meta product (accounts, hacked account, verification texts/calls, payments, ads, etc.), \
please use the official support resources:
- Meta Help Center: https://www.meta.com/help/
- Facebook Help Center: https://www.facebook.com/help/

To keep this repo focused on SDK development, we're going to close this issue as out of scope.

If you believe you've found an SDK-related problem, please open a new issue and include:
- SDK version, Xcode version, iOS version
- steps to reproduce + expected vs actual behavior
- a minimal sample project (if possible) and logs

Thanks for understanding.
"""

# --- Signals -----------------------------------------------------------------

# Known scam numbers seen in this repo (normalized: digits only). Add new ones here.
KNOWN_SCAM_PHONES = {
    "6505434800",
    "18446073947",
    "8446073947",
}

# Generic North-American phone shapes (applied AFTER de-obfuscation).
PHONE_RE = re.compile(r"(?:\+?1[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}")

SEO_MARKERS = [
    "[✍", "[usa]", "call now", "call expert", "helpline", "toll free", "toll-free",
    "support number", "contact number", "customer service", "customer care",
    "technical support", "24/7", "24 7", "live agent", "live person", "1-800", "1 800",
]

# Off-topic brands/topics that never belong in an iOS SDK tracker.
BRAND_TERMS = [
    "cash app", "settlement", "business manager", "meta business", "ads manager",
    "norton", "at&t", "yahoo", "gmail", "outlook", "venmo", "zelle", "paypal",
    "blockchain", "coinbase", "binance", "metamask", "crypto", "robinhood",
    "roku", "youtube", "hulu", "sling", "starz", "quickbooks", "pnc",
    "british airways", "turkish airlines", "sbcglobal", "google account",
]

ACCOUNT_TERMS = [
    "hacked", "recover account", "recover my account", "account recovery",
    "reset password", "forgot password", "password recovery", "regain access",
    "disabled account", "deactivate", "reactivate", "suspended", "dispute",
    "delete account", "compromised", "locked account",
]

# Genuine code / crash-log / stack-trace content. The spam bug-report template
# does NOT contain these — it only echoes SDK *section headers* (e.g. "Xcode
# version", "SPM") and empty code fences — so this is what actually separates a
# real filled-in report from a spam-filled one. (Do NOT veto on bare ``` fences
# or SDK keywords: the template includes both, which would shield spam.)
# Require actual code *syntax*, not lone English words: spam prose contains
# "class action settlement", "guard your account", etc., so bare keywords are
# unsafe. Each alternative below needs code-shaped context.
REAL_CODE_RE = re.compile(
    r"0x[0-9a-fA-F]{6,}"                                   # memory addresses
    r"|\.(?:swift|m|mm|h|kt|java):\d+"                     # file:line references
    r"|-\[FBSDK\w+"                                         # objc selector on an FBSDK class
    r"|@(?:objc|available|implementation|interface|IBOutlet|IBAction)\b"
    r"|\bimport\s+(?:FBSDK\w+|Facebook\w+|UIKit|SwiftUI|Foundation)\b"
    r"|\b(?:func|enum|struct|protocol|extension)\s+\w+\s*[:({<]"   # decl + name + punct
    r"|\bclass\s+\w+\s*[:{]"                                # class Foo: / class Foo {
    # NOTE: no bare `let/var x =` rule — the issue template ships a placeholder
    # `var example = "..."`, which would shield every templated spam issue.
    r"|\b(?:NSException|EXC_BAD_ACCESS|SIGABRT|SIGSEGV)\b"  # crash signals
    r"|Thread\s+\d+\s+(?:Crashed|name)",                   # crash thread header
    re.I,
)
# Title formatting tells: wrapped/decorated in brackets or pipes (e.g. "[[..]]",
# "{{..}}", "|Corporate contact number|", fullwidth/CJK decoration). NOT case-
# insensitive on words — "Support"/"Guide" are ordinary words.
FORMATTING_RE = re.compile(r"\[\[|\]\]|\{\{|\}\}|\|\s*\w|【|】|》|《")

MEMBER_ASSOC = {"MEMBER", "OWNER", "COLLABORATOR", "CONTRIBUTOR"}
# Labels the issue TEMPLATE applies automatically (not human curation) — these
# must NOT veto, or every templated spam issue would be shielded. Anything else
# present is treated as maintainer-curated and does veto.
SAFE_LABELS = {"", "needs-triage", "bug", "question", SPAM_LABEL}


def deobfuscate(s: str) -> str:
    """NFKC-fold styled/fullwidth unicode and common letter-for-digit swaps."""
    s = unicodedata.normalize("NFKC", s)
    s = s.translate(str.maketrans({"O": "0", "o": "0", "I": "1", "l": "1", "S": "5", "B": "8"}))
    return s


def digits(s: str) -> str:
    return re.sub(r"\D", "", s)


def has_phone(text: str):
    d = deobfuscate(text)
    for m in PHONE_RE.finditer(d):
        num = digits(m.group(0))
        if 10 <= len(num) <= 11:
            tail = num[-10:]
            known = (num in KNOWN_SCAM_PHONES) or (tail in KNOWN_SCAM_PHONES) or \
                    (("1" + tail) in KNOWN_SCAM_PHONES)
            return True, known
    return False, False


def count_hits(text: str, terms) -> int:
    return sum(1 for t in terms if t in text)


# The bug-report template has "Xcode version" / "Facebook iOS SDK version" fields.
# Genuine reporters fill them with a plausible version even when they're too lazy
# to paste code (e.g. "Xcode 26.5", "18.0.3", "Latest"); the spam waves fill them
# with gibberish ("dfd", "him"). So a plausible version field is a strong "real
# report" signal that does NOT depend on a code block. (The code placeholder
# `var example = "..."` is intentionally NOT used as a signal: lazy devs leave it.)
_VERSION_HEADERS = ("Xcode version", "Facebook iOS SDK version")


def has_plausible_version(body: str) -> bool:
    for header in _VERSION_HEADERS:
        m = re.search(r"###\s*" + re.escape(header) + r"\s*\n+([^\n#]{0,40})", body, re.I)
        if not m:
            continue
        val = m.group(1).strip().lower()
        if re.search(r"\d+\.\d", val) or re.search(r"xcode\s*\d", val) or "latest" in val:
            return True
    return False


def classify(issue, author_days=None, author_repos=None, author_followers=None):
    """Return (decision, confidence, reasons, score).

    author_* come from the issue author's GitHub profile (see issue #2864); pass
    None on the first (cheap) pass and real values on the re-score for candidates.
    """
    title = issue.get("title") or ""
    body = issue.get("body") or ""
    blob = f"{title}\n{body}".lower()
    assoc = (issue.get("author_association") or "").upper()
    labels = {l["name"].lower() for l in issue.get("labels", [])}

    reasons = []
    full = f"{title}\n{body}"

    # ---- Hard-ham veto: never touch genuine / maintainer issues ----
    nonsafe_labels = labels - SAFE_LABELS
    if assoc in MEMBER_ASSOC:
        return "skip", "ham", [f"author is {assoc}"], 0
    if nonsafe_labels:
        return "skip", "ham", [f"labeled: {','.join(sorted(nonsafe_labels))}"], 0
    if REAL_CODE_RE.search(full):
        return "skip", "ham", ["contains real code / stack-trace content"], 0

    # ---- Spam scoring (phone-centric) ----
    score = 0
    phone, known = has_phone(full)
    seo = count_hits(blob, SEO_MARKERS)
    brand = count_hits(blob, BRAND_TERMS)
    acct = count_hits(blob, ACCOUNT_TERMS)
    fmt = bool(FORMATTING_RE.search(title))
    other_spam = bool(seo or brand or acct or fmt)

    if known:
        score += 100
        reasons.append("known scam phone number")
    elif phone and other_spam:
        score += 60
        reasons.append("phone number + spam context")
    # A lone phone-shaped number with NO other spam signal is ignored on purpose:
    # it may be a timestamp / address in a genuine report.

    if seo:
        score += min(seo * 35, 70)
        reasons.append(f"{seo} support/SEO marker(s)")
    if brand:
        score += min(brand * 30, 60)
        reasons.append(f"{brand} off-topic brand term(s)")
    if acct:
        score += min(acct * 20, 40)
        reasons.append(f"{acct} account/recovery term(s)")
    if fmt:
        score += 20
        reasons.append("decorative title formatting")

    # Lazy-but-real guard: a plausible version field means a genuine reporter even
    # if they pasted no code. Strong reduction (not a hard veto, in case future
    # spam fakes a version) — a known scam phone still forces a close below.
    if not known and has_plausible_version(body):
        score -= 50
        reasons.append("plausible version field (likely real): -50")

    # ---- Account-age heuristic (issue #2864) ----
    # Adjusts an already-suspicious issue; never the sole basis to act. Fresh
    # throwaway accounts boost the score; long-established accounts reduce it.
    if author_days is not None:
        if author_days < VERY_NEW_ACCOUNT_DAYS:
            score += 50
            reasons.append(f"author account {author_days}d old (<{VERY_NEW_ACCOUNT_DAYS}d)")
        elif author_days < NEW_ACCOUNT_DAYS:
            score += 35
            reasons.append(f"author account {author_days}d old (<{NEW_ACCOUNT_DAYS}d)")
        elif author_days > ESTABLISHED_ACCOUNT_DAYS:
            score -= 25
            reasons.append(f"established account ({author_days}d): -25")
        if author_days < ESTABLISHED_ACCOUNT_DAYS and (author_repos or 0) == 0 and (author_followers or 0) == 0:
            score += 10
            reasons.append("no public repos/followers")

    if known or score >= CLOSE_THRESHOLD:
        return "close", "high", reasons, score
    if score >= LABEL_THRESHOLD:
        return "label", "medium", reasons, score
    return "skip", "low", reasons or ["no strong signals"], score


def gh_json(args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out) if out.strip() else None


def load_open_issues():
    # REST API gives author_association + labels + body in one paginated call;
    # filter out PRs (which the issues endpoint also returns).
    data = gh_json([
        "api", "--paginate",
        f"repos/{REPO}/issues?state=open&per_page=100",
    ])
    items = data if isinstance(data, list) else []
    return [i for i in items if "pull_request" not in i]


def recent(issue) -> bool:
    ts = issue.get("updated_at") or issue.get("created_at")
    if not ts:
        return True
    when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return when >= datetime.now(timezone.utc) - timedelta(days=LOOKBACK_DAYS)


def ensure_label():
    if DRY_RUN:
        return
    subprocess.run(
        ["gh", "label", "create", SPAM_LABEL, "--repo", REPO, "--color", "BFD4F2",
         "--description", "Auto-flagged likely spam, pending human review", "--force"],
        capture_output=True, text=True,
    )
    subprocess.run(
        ["gh", "label", "create", CONFIRMED_SPAM_LABEL, "--repo", REPO, "--color", "3f1307",
         "--description", "Spamming issues created by bots for higher ranking in SEO/LLM SEO or other reasons.",
         "--force"],
        capture_output=True, text=True,
    )


def do_close(n):
    # Replace ALL existing labels with just `spam` BEFORE closing. Confirmed spam
    # isn't a real bug/enhancement, so strip the template labels (bug, enhancement,
    # needs-triage, …) and leave only `spam` so the closure is cleanly attributed
    # and auditable. The PUT labels endpoint sets the full label set atomically.
    #
    # If the relabel fails (e.g. a transient GitHub secondary rate-limit during a
    # bulk run) skip the close and return False so this issue is retried on the
    # next run: we never close an issue without the `spam` label, and one transient
    # error can't abort the rest of the run. Returns True only once it is closed.
    try:
        subprocess.run(
            ["gh", "api", "--method", "PUT", f"repos/{REPO}/issues/{n}/labels",
             "-f", f"labels[]={CONFIRMED_SPAM_LABEL}"],
            check=True, capture_output=True, text=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"  - relabel #{n} FAILED, skipping close (will retry next run): {e.stderr.strip()[:120]}")
        return False
    subprocess.run(
        ["gh", "issue", "close", str(n), "--repo", REPO, "--reason", "not planned",
         "--comment", SPAM_COMMENT],
        check=True, capture_output=True, text=True,
    )
    return True


def do_label(n):
    subprocess.run(
        ["gh", "issue", "edit", str(n), "--repo", REPO, "--add-label", SPAM_LABEL],
        check=True, capture_output=True, text=True,
    )


def summary(lines):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    text = "\n".join(lines)
    print(text)
    if path:
        with open(path, "a") as f:
            f.write(text + "\n")


def main():
    if not REPO:
        print("REPO env required", file=sys.stderr)
        return 2

    issues = load_open_issues()
    scanned = [i for i in issues if recent(i)]

    author_cache = {}

    def author_signals(login):
        """(account_age_days, public_repos, followers) for a login; cached. (#2864)"""
        if not login:
            return (None, None, None)
        if login in author_cache:
            return author_cache[login]
        info = (None, None, None)
        try:
            u = gh_json(["api", f"users/{login}"])
            if u and u.get("created_at"):
                created = datetime.fromisoformat(u["created_at"].replace("Z", "+00:00"))
                days = (datetime.now(timezone.utc) - created).days
                info = (days, u.get("public_repos"), u.get("followers"))
        except Exception:
            pass  # fail open: no age signal rather than blocking the run
        author_cache[login] = info
        return info

    to_close, to_label = [], []
    for it in scanned:
        # Cheap first pass (no author lookup).
        decision, conf, reasons, score = classify(it)
        # Only spend an API call on author age when there's already some signal.
        if not (decision == "skip" and score < INVESTIGATE_THRESHOLD):
            login = (it.get("user") or {}).get("login")
            days, repos, followers = author_signals(login)
            decision, conf, reasons, score = classify(it, days, repos, followers)
        if decision == "close":
            to_close.append((it["number"], decision, conf, "; ".join(reasons), it.get("title", "")[:80]))
        elif decision == "label":
            to_label.append((it["number"], decision, conf, "; ".join(reasons), it.get("title", "")[:80]))

    out = ["## Spam triage", "",
           f"- mode: **{'DRY RUN' if DRY_RUN else 'LIVE'}**",
           f"- open issues: {len(issues)} (scanned last {LOOKBACK_DAYS}d: {len(scanned)})",
           f"- to close: {len(to_close)} | to label: {len(to_label)}", ""]

    # Tripwire: refuse to mass-close if something looks wrong.
    if len(to_close) > TRIPWIRE:
        out += [f"> ⚠️ **Tripwire:** {len(to_close)} close candidates exceeds TRIPWIRE={TRIPWIRE}. "
                "Closing ABORTED — please review the pattern manually.", ""]
        summary(out + _table(to_close, "Would close (NOT closed)"))
        return 0

    ensure_label()

    closed = labeled = 0
    for n, _, conf, reasons, title in to_close:
        if closed >= MAX_CLOSE:
            break
        if DRY_RUN:
            closed += 1
            continue
        try:
            if do_close(n):
                closed += 1
            else:
                out.append(f"  - close #{n} SKIPPED: could not apply '{CONFIRMED_SPAM_LABEL}' label (will retry next run)")
        except subprocess.CalledProcessError as e:
            out.append(f"  - close #{n} FAILED: {e.stderr.strip()[:120]}")

    for n, _, conf, reasons, title in to_label:
        if labeled >= MAX_LABEL:
            break
        if DRY_RUN:
            labeled += 1
            continue
        try:
            do_label(n)
            labeled += 1
        except subprocess.CalledProcessError as e:
            out.append(f"  - label #{n} FAILED: {e.stderr.strip()[:120]}")

    verb = "would close" if DRY_RUN else "closed"
    verbl = "would label" if DRY_RUN else "labeled"
    out += [f"- {verb}: {closed} | {verbl}: {labeled}", ""]
    out += _table(to_close, f"Closed ({verb})")
    out += _table(to_label, f"Labeled ({verbl})")
    summary(out)
    return 0


def _table(rows, heading):
    if not rows:
        return []
    md = [f"### {heading}", "", "| # | conf | title | reasons |", "|---|------|-------|---------|"]
    for n, _, conf, reasons, title in rows:
        t = title.replace("|", "\\|")
        r = reasons.replace("|", "\\|")
        md.append(f"| #{n} | {conf} | {t} | {r} |")
    md.append("")
    return md


if __name__ == "__main__":
    sys.exit(main())
