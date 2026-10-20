#!/usr/bin/env python3
"""Validate immutable release source without publishing anything."""
import datetime
import json
import os
from pathlib import Path
import re
import subprocess


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def notes_for(text, version):
    matches = list(re.finditer(r"^## \[?" + re.escape(version) + r"\]? - (\d{4}-\d{2}-\d{2})\s*$", text, re.M))
    if len(matches) != 1:
        raise ValueError("expected exactly one dated changelog section for " + version)
    match = matches[0]
    datetime.date.fromisoformat(match[1])
    notes = re.split(r"^## ", text[match.end():], maxsplit=1, flags=re.M)[0].strip()
    if not notes:
        raise ValueError("release notes are empty")
    return notes + "\n"


def signed_tag(tag):
    ref = f"refs/tags/{tag}"
    if git("cat-file", "-t", ref) != "tag":
        raise ValueError("release and recovery tags must be annotated")
    git("-c", "gpg.format=ssh", "-c", "gpg.ssh.allowedSignersFile=.github/release-allowed-signers", "verify-tag", ref)
    return git("rev-parse", f"{ref}^{{}}"), git("rev-parse", ref)


def main():
    dry = os.environ.get("DRY_RUN") == "true"
    recovery = re.fullmatch(r"refs/tags/(release-recovery/(v[0-9]+\.[0-9]+\.[0-9]+)/[1-9][0-9]*)", os.environ["GITHUB_REF"])
    text = Path("CHANGELOG.md").read_text()
    version = recovery[2][1:] if recovery else os.environ.get("VERSION", "").removeprefix("v")
    if not version and dry:
        version = re.search(r"^## \[?(\d+\.\d+\.\d+)\]? - \d{4}-\d{2}-\d{2}", text, re.M)[1]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?", version):
        raise ValueError("release version must be SemVer")
    tag = "v" + version
    head = git("rev-parse", "HEAD")
    source = head
    repo = os.environ["GITHUB_REPOSITORY"]
    branch = api(f"repos/{repo}/branches/main")
    if not branch["protected"]:
        raise ValueError("main must be protected")
    git("merge-base", "--is-ancestor", head, "origin/main")
    tag_object = ""
    recovery_tag_object = ""
    if dry:
        if os.environ["GITHUB_REF"] != "refs/heads/main":
            raise ValueError("dispatch dry runs from main")
    else:
        if os.environ["GITHUB_EVENT_NAME"] != "push" or (not recovery and os.environ["GITHUB_REF"] != f"refs/tags/{tag}"):
            raise ValueError("publish only from a signed version-tag push")
        if recovery:
            recovery_head, recovery_tag_object = signed_tag(recovery[1])
            if recovery_head != head:
                raise ValueError("recovery tag must freeze HEAD")
        source, tag_object = signed_tag(tag)
        if not recovery and source != head:
            raise ValueError("release tag must be annotated and freeze HEAD")
        git("merge-base", "--is-ancestor", source, head)
        text = git("show", f"{source}:CHANGELOG.md")
        releases = api(f"repos/{repo}/releases?per_page=100")
        if any(r["tag_name"] == tag for r in releases):
            raise ValueError("release already exists; never overwrite it")
    metadata_text = Path("version.env").read_text() if dry else git("show", f"{source}:version.env")
    metadata = dict(line.split("=", 1) for line in metadata_text.splitlines() if "=" in line)
    if metadata.get("VERSION") != version:
        raise ValueError("version.env must match release version")
    for workflow in os.environ["CI_WORKFLOWS"].split(","):
        for commit in dict.fromkeys([head, source]):
            runs = api(f"repos/{repo}/actions/workflows/{workflow}/runs?head_sha={commit}&event=push&branch=main&per_page=100")["workflow_runs"]
            if not any(r["head_sha"] == commit and r["event"] == "push" and r.get("head_branch") == "main" and r["conclusion"] == "success" for r in runs):
                raise ValueError(f"no green push {workflow} on {commit}")
    Path("release-notes.md").write_text(notes_for(text, version))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"version={version}\ntag={tag}\nsha={source}\ntag_object={tag_object}\n")
        output.write(f"recovery_tag={recovery[1] if recovery else ''}\nrecovery_tag_object={recovery_tag_object}\n")


if __name__ == "__main__":
    main()
