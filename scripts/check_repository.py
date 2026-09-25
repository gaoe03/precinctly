#!/usr/bin/env python3
"""Read-only checks of files eligible for the next commit and commit messages."""
import argparse
from pathlib import Path
import re
import subprocess


ATTRIBUTION = re.compile(
    r"\b(?:cla[u]de|anthro[p]ic|code[x]|chat[g]pt|open[a]i|copi[l]ot)\b"
    r"|\b(?:generated|written|built|assisted)\s+by\s+(?:an?\s+)?A[I]\b"
    r"|co-authored[-]by:", re.I
)
SECRETS = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
    r"|\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{30,}"
    r"|\bAKIA[A-Z0-9]{16}\b|\bsk-[A-Za-z0-9_-]{30,}"
)
PRIVATE_PARTS = {"public_data", "backups", "node_modules", "DerivedData", "build", "notes", "appstore-screenshots"}


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def scan(root, base=None):
    names = set(git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
                .decode().split("\0")) - {""}
    issues = []
    # Tracked files that an ignore rule covers, including the machine-wide excludes file that
    # lists per-user tool config. Ignoring a file later must not hide that it was committed.
    for name in sorted(set(git(root, "ls-files", "-ci", "--exclude-standard", "-z").decode().split("\0")) - {""}):
        issues.append(f"{name}: tracked file matches an ignore rule")
    for name in sorted(names):
        path = root / name
        # Tracked deletions are not part of the next working-tree commit.
        if not path.exists() and not path.is_symlink():
            continue
        parts = Path(name).parts
        if (set(parts) & PRIVATE_PARTS or any(p.endswith(".xcodeproj") or p.startswith("build-") for p in parts)
                or re.search(r"\.(?:db|sqlite)(?:-(?:shm|wal|journal))?$", name)
                or Path(name).name in {".env", "id_rsa", "id_ed25519"}
                or Path(name).name.startswith(".env.") and not name.endswith(".example")):
            issues.append(f"{name}: private or generated file is eligible for commit")
            continue
        if path.is_symlink():
            issues.append(f"{name}: review symlink before committing")
            continue
        if path.stat().st_size > 10 * 1024 * 1024:
            issues.append(f"{name}: file exceeds 10 MiB")
            continue
        data = path.read_bytes()
        if b"\0" in data[:8192]:
            continue
        for line_number, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
            if SECRETS.search(line):
                issues.append(f"{name}:{line_number}: possible credential (value withheld)")
            # The policy itself necessarily names the terms it rejects.
            policy_line = name == "scripts/check_repository.py"
            if not policy_line and ATTRIBUTION.search(line):
                issues.append(f"{name}:{line_number}: unwanted attribution or tool reference")
    revisions = [f"{base}..HEAD"] if base else ["--all"]
    messages = git(root, "log", *revisions, "--format=%h%x00%B%x00").decode()
    fields = messages.split("\0")
    for index in range(0, len(fields) - 1, 2):
        if ATTRIBUTION.search(fields[index + 1]):
            issues.append(f"commit {fields[index].strip()}: unwanted attribution")
    return issues, len(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Check commit messages in BASE..HEAD instead of all local refs")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        issues, count = scan(root, args.base)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Repository check could not complete: {type(error).__name__}")
        return 1
    for issue in issues:
        print(issue)
    if issues:
        return 1
    print(f"Repository check passed for {count} candidate files and local commit messages.")
    print("This checks the working tree. Review staged content separately before committing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
