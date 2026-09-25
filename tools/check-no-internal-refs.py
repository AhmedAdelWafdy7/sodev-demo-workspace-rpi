#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Find text a reader of this tree cannot resolve.

Comments and patch descriptions in this tree carry measurements and the
reasoning behind them. Some of that text names things a reader of the tree
cannot resolve and should not have to: a personal home directory, the MAC of
a real machine, text in another language, a document or a tool that is not in
the tree. This script finds such text.

It uses two kinds of rule.

  The generic rules are written below. They hold for any site: a personal
  home directory, a MAC outside the synthetic ranges this tree uses, CJK text,
  a weekday, and a pointer to a procedure the reader cannot see.

  The site vocabulary -- the names of one site's documents, tools, hosts and
  directories -- is not written in the tree, because listing those names
  would publish them. It is read from a file that is not under version
  control, one rule per line:

      <rule-name>: <Python regular expression>

  Blank lines and lines starting with '#' are ignored. The file is the first
  of --vocab FILE, $CHECK_INTERNAL_REFS_VOCAB and tools/.internal-refs, which
  .gitignore excludes. Without one, only the generic rules run, and the
  report says so.

It is a lint, not a security boundary. It matches text, so it cannot know
whether a short word is an SSID, and it can be fooled on purpose. What it does
reliably is catch the accident.

Usage:

    tools/check-no-internal-refs.py [--vocab FILE] [PATH ...]
    tools/check-no-internal-refs.py [--vocab FILE] --added REV

It scans the files under each PATH (default: the whole tree) that git
tracks, and the untracked ones .gitignore does not exclude; when the tree is
not a git checkout, it scans every file. --added REV scans only the lines the
working tree adds relative to REV, and every line of those untracked files.
Gate a submission with --added: text that predates the range is not the
submission's to fix.

Exit status: 0 if nothing matched, 1 if something did, 2 on a usage error or
a vocabulary file that cannot be used.
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_VOCAB = os.path.join("tools", ".internal-refs")
VOCAB_ENV = "CHECK_INTERNAL_REFS_VOCAB"

# Each rule: (name, regex, why it matters).
GENERIC_RULES = [
    # /home/root is the root home on the target images and /home/builder the
    # build container's user; neither is a person's account.
    ("home-dir",
     r"/home/(?!root\b|builder\b)[a-z][a-z0-9_-]*\b",
     "a personal home directory; use a variable or a relative path"),
    # The ranges this tree uses on purpose are subtracted: 08:00:27 (the guest
    # NICs, as in the upstream domain configs), 02:15:b2 (the prefix the
    # cuttlefish guest gives its mac80211_hwsim radios), 00:16:3e (Xen's) and
    # the aa:bb:cc placeholder.
    ("real-mac",
     r"(?i)(?<![0-9a-f:])(?!08:00:27|02:15:b2|00:16:3e|aa:bb:cc)"
     r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f:])",
     "a MAC outside the synthetic ranges this tree uses"),
    # CJK punctuation, kana, the unified ideographs and the full-width forms.
    ("cjk",
     r"[\u3000-\u30ff\u4e00-\u9fff\uff00-\uffef]+",
     "CJK text; this tree is written in English"),
    ("weekday",
     r"\b(?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day(?:'s)?\b",
     "a weekday dates a session, not the code"),
    ("first-person-procedure",
     r"\bour\s+(?:[a-z-]+\s+){0,3}"
     r"(?:procedure|process|notes|records|bring-up)\b",
     "points at a procedure the reader cannot see"),
]

SKIP_DIRS = {".git", "__pycache__", ".ninja_deps", "yocto", "build", "out"}
SKIP_SUFFIX = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zst", ".xz",
               ".gz", ".bz2", ".img", ".bin", ".so", ".o", ".a", ".pyc",
               ".jar", ".apk", ".ttf", ".woff", ".woff2")


def die(msg):
    sys.stderr.write("check-no-internal-refs: %s\n" % msg)
    sys.exit(2)


def find_vocab(opt):
    """(path or None, where it came from). A file that was asked for by
    name and is missing is an error; the default is optional."""
    if opt:
        return opt, "--vocab"
    env = os.environ.get(VOCAB_ENV)
    if env:
        return env, "$" + VOCAB_ENV
    path = os.path.join(ROOT, DEFAULT_VOCAB)
    return (path, DEFAULT_VOCAB) if os.path.isfile(path) else (None, None)


def load_vocab(path):
    rules = []
    try:
        fh = open(path, encoding="utf-8")
    except OSError as e:
        die("cannot read the vocabulary %s: %s" % (path, e.strerror))
    with fh:
        for n, line in enumerate(fh, 1):
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            m = re.match(r"([a-z0-9][a-z0-9-]*):\s*(.+)$", text)
            if not m:
                die("%s:%d: expected '<rule-name>: <regex>'" % (path, n))
            try:
                re.compile(m.group(2))
            except re.error as e:
                die("%s:%d: %s" % (path, n, e))
            rules.append((m.group(1), m.group(2), "site vocabulary"))
    if not rules:
        die("%s has no rules" % path)
    return rules


def git(*args):
    return subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True)


def is_git_checkout():
    r = git("rev-parse", "--show-toplevel")
    top = r.stdout.decode().strip()
    return r.returncode == 0 and os.path.realpath(top) == os.path.realpath(ROOT)


def interesting(rel, skip):
    return rel not in skip and not rel.endswith(SKIP_SUFFIX)


def rel_of(p):
    ap = p if os.path.isabs(p) else os.path.join(ROOT, p)
    return os.path.relpath(ap, ROOT)


def tracked(paths, skip):
    r = git("-c", "core.quotePath=false", "ls-files", "-z", "--cached",
            "--others", "--exclude-standard", "--", *[rel_of(p) for p in paths])
    if r.returncode:
        die("git ls-files failed: %s" % r.stderr.decode().strip())
    for rel in r.stdout.decode().split("\0"):
        if (rel and interesting(rel, skip)
                and os.path.isfile(os.path.join(ROOT, rel))):
            yield rel


def walk(paths, skip):
    for p in paths:
        ap = os.path.join(ROOT, rel_of(p))
        if os.path.isfile(ap):
            if interesting(rel_of(ap), skip):
                yield rel_of(ap)
            continue
        for dirpath, dirnames, filenames in os.walk(ap):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for f in filenames:
                rel = rel_of(os.path.join(dirpath, f))
                if interesting(rel, skip):
                    yield rel


def added_lines(rev, skip):
    """(path, line number, text) for every line the working tree adds
    relative to rev, then every line of each untracked, not ignored file."""
    r = git("-c", "core.quotePath=false", "diff", "-U0", "--no-color",
            "--no-ext-diff", rev, "--")
    if r.returncode:
        die("git diff %s failed: %s" % (rev, r.stderr.decode().strip()))
    # A "+++ " line is a file header only between "diff --git" and the
    # file's first "@@"; inside a hunk it is an added line whose text starts
    # with "++ ".
    path, lineno, header = None, 0, False
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("diff --git "):
            path, header = None, True
        elif header and line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            header = False
            m = re.match(r"@@ -\S+ \+(\d+)", line)
            lineno = int(m.group(1)) if m else 0
        elif line.startswith("+") and path:
            if interesting(path, skip):
                yield path, lineno, line[1:]
            lineno += 1
    r = git("-c", "core.quotePath=false", "ls-files", "-z", "--others",
            "--exclude-standard")
    for rel in r.stdout.decode().split("\0"):
        if rel and interesting(rel, skip):
            for n, text in read_lines(rel):
                yield rel, n, text


def read_lines(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            return list(enumerate(fh, 1))
    except UnicodeDecodeError:
        print("  skipped (not UTF-8): %s" % rel)
    except OSError as e:
        print("  skipped (%s): %s" % (e.strerror, rel))
    return []


def scan_text(rules, rel, lineno, text, hits):
    seen = set()
    for name, pat, why in rules:
        if name in seen:
            continue
        m = re.search(pat, text)
        if m:
            # One hit per rule per line: a line that trips a rule three times
            # is one thing to fix.
            seen.add(name)
            hits.append((rel, lineno, name, m.group(0), why,
                         text.strip()[:120]))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vocab", metavar="FILE",
                    help="site vocabulary file (default: $%s, then %s)"
                    % (VOCAB_ENV, DEFAULT_VOCAB))
    ap.add_argument("--added", metavar="REV",
                    help="scan only the lines the working tree adds "
                    "relative to REV")
    ap.add_argument("paths", nargs="*", metavar="PATH")
    args = ap.parse_args()
    if args.added and args.paths:
        ap.error("--added takes no PATH")

    rules = list(GENERIC_RULES)
    vocab, source = find_vocab(args.vocab)
    skip = set()
    if vocab:
        site = load_vocab(vocab)
        rules += site
        skip.add(rel_of(os.path.abspath(vocab)))
        print("rules: %d generic + %d site (%s: %s)"
              % (len(GENERIC_RULES), len(site), source, vocab))
    else:
        print("rules: %d generic, no site vocabulary (none given by --vocab "
              "or $%s, and no %s)"
              % (len(GENERIC_RULES), VOCAB_ENV, DEFAULT_VOCAB))

    hits = []
    if args.added:
        print("scanning lines added since %s" % args.added)
        for rel, n, text in added_lines(args.added, skip):
            scan_text(rules, rel, n, text, hits)
    else:
        paths = args.paths or ["."]
        if is_git_checkout():
            print("scanning the files git tracks or does not ignore under %s"
                  % ", ".join(paths))
            files = tracked(paths, skip)
        else:
            print("scanning every file under %s (not a git checkout)"
                  % ", ".join(paths))
            files = walk(paths, skip)
        for rel in sorted(files):
            for n, text in read_lines(rel):
                scan_text(rules, rel, n, text, hits)

    if not hits:
        print("no internal references found")
        return 0

    by_rule = {}
    for h in hits:
        by_rule.setdefault(h[2], []).append(h)
    for name in sorted(by_rule, key=lambda k: [r[0] for r in rules].index(k)):
        rows = by_rule[name]
        print("\n== %s (%d) -- %s" % (name, len(rows), rows[0][4]))
        for rel, lineno, _n, s, _w, text in rows:
            print("  %s:%d\n      matched %r in: %s" % (rel, lineno, s, text))
    print("\n%d match(es) in %d rule(s)" % (len(hits), len(by_rule)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
