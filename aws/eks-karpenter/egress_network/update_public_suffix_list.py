#!/usr/bin/env python3
"""Vendor the Public Suffix List as an ASCII (IDNA/Punycode) rule file.

The module validates lowercase ASCII/Punycode domain names, so every Unicode
rule in the upstream list (e.g. 公司.cn) must be vendored in its ASCII form
(xn--55qx5d.cn) or wildcard/public-suffix checks silently miss it. This script
is the only sanctioned way to refresh public_suffix_list.dat: it rewrites every
rule label with the stdlib IDNA codec, keeps `*.` wildcard and `!` exception
prefixes, and keeps every comment line (MPL-2.0 licence, VERSION, COMMIT,
section markers) verbatim, so the output is deterministic for a given input.

    ./update_public_suffix_list.py                # fetch upstream, rewrite in place
    ./update_public_suffix_list.py --input FILE   # normalise a local copy (offline)
    ./update_public_suffix_list.py --check        # exit 1 if the vendored file is not normalised

Never called at plan/apply time; the module reads only the vendored file.
"""

import argparse
import encodings.idna
import pathlib
import sys
import urllib.request

UPSTREAM = "https://publicsuffix.org/list/public_suffix_list.dat"
HERE = pathlib.Path(__file__).resolve().parent
VENDORED = HERE / "public_suffix_list.dat"


def ascii_label(label: str) -> str:
    if label.isascii():
        return label.lower()
    try:
        return encodings.idna.ToASCII(label).decode("ascii").lower()
    except UnicodeError:
        return "xn--" + label.lower().encode("punycode").decode("ascii")


def normalise_rule(rule: str) -> str:
    prefix = ""
    if rule.startswith("!"):
        prefix, rule = "!", rule[1:]
    labels = rule.split(".")
    return prefix + ".".join("*" if label == "*" else ascii_label(label) for label in labels)


def normalise(text: str) -> str:
    out = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            out.append(raw.rstrip())
        else:
            out.append(normalise_rule(line))
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=pathlib.Path, help="local upstream copy instead of fetching")
    parser.add_argument("--output", type=pathlib.Path, default=VENDORED)
    parser.add_argument("--check", action="store_true", help="verify the vendored file is already normalised")
    args = parser.parse_args()

    if args.check:
        current = args.output.read_text(encoding="utf-8")
        if normalise(current) != current:
            print(f"{args.output} is not normalised; rerun without --check", file=sys.stderr)
            return 1
        print(f"{args.output} is normalised ASCII")
        return 0

    if args.input:
        source = args.input.read_text(encoding="utf-8")
    else:
        with urllib.request.urlopen(UPSTREAM, timeout=30) as response:
            source = response.read().decode("utf-8")
    normalised = normalise(source)
    if any(not line.isascii() for line in normalised.splitlines() if line and not line.startswith("//")):
        print("normalisation left a non-ASCII rule", file=sys.stderr)
        return 1
    args.output.write_text(normalised, encoding="utf-8")
    print(f"wrote {args.output} ({sum(1 for l in normalised.splitlines() if l and not l.startswith('//'))} rules)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
