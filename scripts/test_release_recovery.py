"""Exercise the production release guards with real signatures and controlled GitHub transport."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parent.parent
TAG = "v1.2.3"
RECOVERY = "release-recovery/v1.2.3/1"
ARCHIVE = "openclaw-facetime-macos-arm64.zip"
PAYLOAD = b"synthetic original native payload\n"

GH_TRANSPORT = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
path = pathlib.Path(os.environ['FIXTURE_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
if args[0] == 'api':
    endpoint = args[1]
    if '/branches/main' in endpoint:
        print(json.dumps({'protected': True}))
    elif '/releases?' in endpoint:
        print('[]')
    elif '/actions/workflows/' in endpoint:
        sha = endpoint.split('head_sha=')[1].split('&')[0]
        assert sha in state['commits']
        print(json.dumps({'workflow_runs': [{'head_sha': sha, 'event': 'push', 'head_branch': 'main', 'conclusion': 'success'}]}))
    else:
        raise SystemExit('unexpected API read')
elif args[:2] == ['release', 'create']:
    assert args[2] == state['tag'] and '--draft' in args and '--verify-tag' in args
    state['writes'].append('create')
    state['notes'] = pathlib.Path(args[args.index('--notes-file') + 1]).read_text()
    assets = [pathlib.Path(a) for a in args[3:] if a.startswith('release-assets/')]
    state['assets'] = {a.name: a.read_bytes().hex() for a in assets}
    assert hashlib.sha256(bytes.fromhex(state['assets'][state['archive']])).hexdigest() == state['expected_sha']
elif args[:2] == ['release', 'download']:
    assert args[2] == state['tag']
    target = pathlib.Path(args[args.index('--dir') + 1])
    target.mkdir()
    for name, content in state['assets'].items():
        (target / name).write_bytes(bytes.fromhex(content))
elif args[:2] == ['release', 'edit']:
    assert args[2:] == [state['tag'], '--draft=false']
    state['writes'].append('publish')
else:
    raise SystemExit('unexpected GitHub command')
path.write_text(json.dumps(state))
'''


def command(args, cwd, env, check=True):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if check and result.returncode:
        raise AssertionError(f"{args[0]} failed: {result.stderr}")
    return result


def exercise(base, case, key, unauthorized_key, publication):
    folder = base / case
    folder.mkdir()
    repo, remote = folder / "repo", folder / "remote.git"
    repo.mkdir()
    home, bin_dir = folder / "home", folder / "bin"
    home.mkdir()
    bin_dir.mkdir()
    env = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "HOME": str(home),
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
           "GIT_TERMINAL_PROMPT": "0", "FIXTURE_STATE": str(folder / "state.json")}
    def git(*args, check=True):
        return command(["git", *args], repo, env, check)
    command(["git", "init", "--bare", str(remote)], folder, env)
    git("init", "-b", "main")
    for name, value in [("user.name", "Recovery fixture"), ("user.email", "fixture@example.invalid"),
                        ("gpg.format", "ssh"), ("user.signingkey", str(key))]:
        git("config", name, value)
    (repo / ".github").mkdir()
    (repo / ".github/release-allowed-signers").write_text('release namespaces="git" ' + key.with_suffix('.pub').read_text())
    (repo / "scripts").mkdir()
    (repo / "scripts/release-preflight.py").write_text((ROOT / "scripts/release-preflight.py").read_text())
    (repo / "CHANGELOG.md").write_text("## 1.2.3 - 2026-10-20\n\n- Frozen original notes\n")
    (repo / "version.env").write_text("VERSION=1.2.3\n")
    (repo / "Makefile").write_text("native-verify:\n\tpython3 -c \"from pathlib import Path; assert Path('bin/" + ARCHIVE + "').read_bytes() == " + repr(PAYLOAD) + "\"\n")
    git("add", ".")
    git("commit", "-m", "Original synthetic release")
    source = git("rev-parse", "HEAD").stdout.strip()
    git("tag", "-s", TAG, "-m", "Original synthetic version")
    (repo / "CHANGELOG.md").write_text("## 9.9.9 - 2026-10-20\n\n- Controller notes must not publish\n")
    (repo / "version.env").write_text("VERSION=9.9.9\n")
    git("add", ".")
    git("commit", "-m", "Synthetic repaired controller")
    controller = git("rev-parse", "HEAD").stdout.strip()
    git("tag", "-s", RECOVERY, "-m", "Authorize synthetic recovery")
    git("remote", "add", "origin", str(remote))
    if case.startswith("unauthorized"):
        changed = RECOVERY if case == "unauthorized-recovery" else TAG
        git("-c", "user.signingkey=" + str(unauthorized_key), "tag", "-f", "-s", changed, "-m", "Untrusted fixture")
    git("push", "-u", "origin", "main", "--tags")
    git("fetch", "origin")
    state_path = Path(env["FIXTURE_STATE"])
    state_path.write_text(json.dumps({"tag": TAG, "archive": ARCHIVE, "commits": [source, controller],
                                      "expected_sha": hashlib.sha256(PAYLOAD).hexdigest(), "writes": []}))
    gh = bin_dir / "gh"
    gh.write_text(GH_TRANSPORT)
    gh.chmod(0o700)
    env.update({"DRY_RUN": "false", "VERSION": RECOVERY, "GITHUB_REPOSITORY": "fixture/recovery",
                "GITHUB_REF": "refs/tags/" + RECOVERY, "GITHUB_EVENT_NAME": "push",
                "CI_WORKFLOWS": "ci.yml", "GITHUB_OUTPUT": str(folder / "outputs")})
    preflight = command([sys.executable, "-B", str(ROOT / "scripts/release-preflight.py")], repo, env, check=False)
    if case.startswith("unauthorized"):
        assert preflight.returncode != 0, case
    else:
        assert preflight.returncode == 0, preflight.stderr
        values = dict(line.split("=", 1) for line in (folder / "outputs").read_text().splitlines())
        assert values["sha"] == source
        if case.startswith("moved"):
            changed = RECOVERY if case == "moved-recovery" else TAG
            (repo / "marker").write_text(case)
            git("add", "marker")
            git("commit", "-m", "Synthetic post-validation movement")
            git("tag", "-f", "-s", changed, "-m", "Moved fixture tag")
            git("push", "--force", "origin", "refs/tags/" + changed)
        elif case == "deleted-recovery":
            command(["git", "--git-dir=" + str(remote), "update-ref", "-d", "refs/tags/" + RECOVERY], folder, env)
        git("checkout", "--detach", source)
        assets = repo / "release-assets"
        assets.mkdir()
        (assets / ARCHIVE).write_bytes(PAYLOAD)
        (assets / (ARCHIVE + ".sha256")).write_text(hashlib.sha256(PAYLOAD).hexdigest() + "  " + ARCHIVE + "\n")
        env.update({"TAG": values["tag"], "TAG_OBJECT": values["tag_object"],
                    "RECOVERY_TAG": values["recovery_tag"], "RECOVERY_TAG_OBJECT": values["recovery_tag_object"]})
        result = command(["/bin/bash", "-e", "-c", publication], repo, env, check=False)
        assert (result.returncode == 0) == (case == "allowed"), (case, result.stderr)
    state = json.loads(state_path.read_text())
    if case == "allowed":
        assert state["writes"] == ["create", "publish"]
        assert state["notes"] == "- Frozen original notes\n"
    else:
        assert state["writes"] == [], (case, state["writes"])
    print(json.dumps({"case": case, "writes": state["writes"], "original_source": source,
                      "controller": controller, "original_payload_sha256": state["expected_sha"]}))


def main():
    workflow = (ROOT / ".github/workflows/release.yml").read_text()
    block = workflow.split("      - name: Reverify tag and publish exact changelog notes\n", 1)[1]
    body = block.split("        run: |\n", 1)[1].split("\n  homebrew:", 1)[0]
    publication = textwrap.dedent(body)
    with tempfile.TemporaryDirectory(prefix="release-recovery-proof-") as directory:
        root = Path(directory)
        key, unauthorized = root / "allowed-key", root / "unauthorized-key"
        for target in [key, unauthorized]:
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(target)], check=True)
        for case in ["allowed", "unauthorized-recovery", "unauthorized-version", "moved-recovery", "deleted-recovery", "moved-version"]:
            exercise(root, case, key, unauthorized, publication)


if __name__ == "__main__":
    main()
