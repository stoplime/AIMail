#!/usr/bin/env python3
"""check_range_code_sha.py -- refuse-loudly guard: every JSON file's own `code_sha` field,
across every commit in a landed range, must equal that commit's real git parent.

ALIAS (fable's landing-law ruling, 2026-09-18): `code_sha_at_generation` is accepted wherever
`code_sha` is, same comparison against the commit's real parent. t784_oracle_docstring_
tripwire_2026-09-09.json has carried `code_sha_at_generation` -- same meaning, same value shape
-- since before this check existed; the check adapts to the record's own existing name rather
than the record being rewritten for the checker's convenience. `code_sha` is preferred when a
JSON carries both (it never has, in practice); presence of either satisfies the probe-lane
"must carry the field" requirement.

WHY: a JSON's own `code_sha` field is a self-referential claim ("this file's content reflects
the code at this git commit"), computed live via `git rev-parse HEAD` at build time -- BEFORE
the commit that lands it exists, so at that moment `HEAD` is the commit's real parent (this
fleet's own standing convention). If the commit that lands the JSON is later rebased, or the
JSON is carried forward unchanged onto a new parent, that claim goes STALE: the field no
longer names the commit that is ACTUALLY that JSON's parent in the landed history.

fable's own manual code_sha sweep (2026-09-18, step 8) found exactly this by hand:
t882_step8_corpus_manifest_2026-09-17.json's own `code_sha` field (fde8d5fd599345cb9a4c2cf
e370bf7713cd416d9) does not match its real landed parent (d78c379479ad75d0838e6f3b998aa65493
a38e4f, commit a9ec29542's own first parent) -- a pre-rebase code_sha carried forward
unchanged when the manifest's own commit was rebased onto a later tip. Ruled non-blocking
that time (self-corrects at the manifest's own next real run) but named the general gap: the
existing pre-ff check this widens only covered probe-only chains where a single seat lands a
single JSON's own commit and can eyeball the mismatch by hand -- this makes the same check
mechanical, over every JSON any commit in a landed range touches, so a multi-commit chain's
own carried-forward or rebased JSON can't go unnoticed the way this one did (PROP-73 row,
main's 2026-09-18 handover).

USAGE:
    check_range_code_sha.py <base-ref> <tip-ref> [--repo PATH]

For every commit in (base-ref, tip-ref] (`git rev-list --reverse base..tip`), for every path
that commit's own diff-tree touches ending in `.json`, reads that path's content AT THAT
COMMIT (`git show <commit>:<path>`), looks for a top-level `"code_sha"` field, and compares it
against that commit's own first parent (`git rev-parse <commit>^`). A JSON deleted at that
commit, or not valid JSON, or not a top-level object, is skipped (nothing to check). A root
commit (no parent) is skipped -- there is no parent for its own JSON to equal.

A JSON with NO `code_sha` field at all is handled by PATH SCOPE, not skipped uniformly (fable's
2026-09-18 additive follow-up, the `88c382733` case: a `tools/audit_probes/*.json` landed with
no `code_sha` field at all that night, ruled a failure BY ABSENCE, not a pass-by-omission):
  - under `tools/audit_probes/` (any depth): a missing field is a REFUSAL, naming the path --
    that lane's own convention is that every probe output carries one; an absent field there
    is the same class of defect as a wrong one, not an opt-out.
  - everywhere else: a missing field is a SKIP, unchanged from before -- not every JSON in this
    repo opts into the convention (a plain data/config JSON never will), and treating absence
    there as a refusal would make this check refuse on files that were never meant to carry
    the field at all.

    --repo PATH   the git repo to check (default: cwd). Every ref and path is resolved
                  against this repo explicitly -- never the ambient shell cwd by itself,
                  matching this fleet's own safe_sync.sh convention (this project's default
                  shell cwd is not reliably inside any one repo).

Exit 0 -- every code_sha-bearing JSON touched anywhere in the range matched its own commit's
          real parent, and no probe-lane JSON was missing the field entirely. Prints a summary
          line (commits scanned, JSONs checked) even when zero JSONs carried the field, so an
          empty/uneventful range doesn't silently look identical to a genuine clean pass over
          real content -- both print the same shape of line, but the count makes the
          difference visible.
Exit 1 -- usage error, an unresolvable ref, or --repo does not resolve to a git working tree.
Exit 2 -- at least one mismatch or missing-field-in-probe-lane refusal found. Nothing is
          fixed; each finding prints the commit and path, plus (for a mismatch) the JSON's own
          claimed code_sha and the real parent it should equal, or (for a missing field) that
          it names an absent field, not a wrong one -- enough to go fix it by hand (this
          script only checks, per its own single responsibility; the acceptance run that
          motivated it left a9ec29542's own manifest mismatch unfixed, ruled non-blocking, not
          this script's call to make either way).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys


PROBE_LANE_PREFIX = "tools/audit_probes/"
CODE_SHA_KEY = "code_sha"
CODE_SHA_ALIAS_KEY = "code_sha_at_generation"


def _git(repo: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base_ref")
    ap.add_argument("tip_ref")
    ap.add_argument("--repo", default=".")
    args = ap.parse_args()

    repo_check = _git(args.repo, "rev-parse", "--show-toplevel")
    if repo_check.returncode != 0:
        print(f"check_range_code_sha.py: '--repo {args.repo}' is not a git working tree.",
              file=sys.stderr)
        sys.exit(1)
    repo = repo_check.stdout.strip()

    for ref in (args.base_ref, args.tip_ref):
        r = _git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
        if r.returncode != 0:
            print(f"check_range_code_sha.py: '{ref}' does not resolve to a commit in {repo}.",
                  file=sys.stderr)
            sys.exit(1)

    rev_list = _git(repo, "rev-list", "--reverse", f"{args.base_ref}..{args.tip_ref}")
    if rev_list.returncode != 0:
        print(f"check_range_code_sha.py: cannot list commits in "
              f"{args.base_ref}..{args.tip_ref}: {rev_list.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    commits = [c for c in rev_list.stdout.splitlines() if c]

    n_checked = 0
    mismatches = []
    missing_in_probe_lane = []
    for commit in commits:
        diff_tree = _git(repo, "diff-tree", "-r", "--no-commit-id", "--name-only", commit)
        json_paths = [p for p in diff_tree.stdout.splitlines() if p.endswith(".json")]
        if not json_paths:
            continue

        parent_result = _git(repo, "rev-parse", f"{commit}^")
        if parent_result.returncode != 0:
            continue  # root commit, no parent to check against
        real_parent = parent_result.stdout.strip()

        for path in json_paths:
            show = _git(repo, "show", f"{commit}:{path}")
            if show.returncode != 0:
                continue  # deleted at this commit
            try:
                doc = json.loads(show.stdout)
            except (json.JSONDecodeError, ValueError):
                continue  # not valid JSON
            if not isinstance(doc, dict):
                continue
            if CODE_SHA_KEY in doc:
                claimed = doc[CODE_SHA_KEY]
            elif CODE_SHA_ALIAS_KEY in doc:
                claimed = doc[CODE_SHA_ALIAS_KEY]
            else:
                if path.startswith(PROBE_LANE_PREFIX):
                    missing_in_probe_lane.append((commit, path))
                continue  # outside the probe lane: doesn't carry the convention, skip
            n_checked += 1
            if claimed != real_parent:
                mismatches.append((commit, path, claimed, real_parent))

    print(f"check_range_code_sha.py: {len(commits)} commit(s) in "
          f"{args.base_ref}..{args.tip_ref}, {n_checked} JSON(s) carrying code_sha checked.")

    if mismatches or missing_in_probe_lane:
        if mismatches:
            print(f"\n⛔ {len(mismatches)} MISMATCH(ES):", file=sys.stderr)
            for commit, path, claimed, real_parent in mismatches:
                print(f"  commit {commit}: {path}", file=sys.stderr)
                print(f"    code_sha claims: {claimed}", file=sys.stderr)
                print(f"    real parent is:  {real_parent}", file=sys.stderr)
        if missing_in_probe_lane:
            print(f"\n⛔ {len(missing_in_probe_lane)} MISSING code_sha IN THE PROBE LANE "
                  f"(absence, not a wrong value -- every {PROBE_LANE_PREFIX}*.json must carry "
                  f"the field):", file=sys.stderr)
            for commit, path in missing_in_probe_lane:
                print(f"  commit {commit}: {path}", file=sys.stderr)
        sys.exit(2)

    print("PASSED: every code_sha-bearing JSON in range matched its own commit's real parent, "
          "and no probe-lane JSON was missing the field.")
    sys.exit(0)


if __name__ == "__main__":
    main()
