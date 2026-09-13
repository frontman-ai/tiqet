"""Native release-gate regression check; all Git writes stay in a new /tmp fixture."""
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

source = Path(__file__).resolve().parents[2]
base = Path(tempfile.mkdtemp(prefix="tiqet-package-test-", dir="/tmp"))
repo = base / "source"
repo.mkdir()
home = base / "home"
home.mkdir()
env = dict(PATH=os.environ["PATH"], HOME=str(home), GIT_CONFIG_NOSYSTEM="1",
           GIT_CONFIG_GLOBAL="/dev/null", ZIG_GLOBAL_CACHE_DIR=str(base / "zig-cache"))


def run(args, expected=0):
    result = subprocess.run(args, cwd=repo, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    with (base / "commands.log").open("ab") as log:
        log.write((repr(args) + "\n").encode() + result.stdout)
    assert result.returncode == expected, (args, result.returncode, result.stdout.decode())
    return result.stdout


def package(name, success=False, message=None):
    output = base / name
    result = run(["just", "--justfile", "apps/cli/justfile", "--working-directory", "apps/cli",
                  "package", str(output), "release"], 0 if success else 1)
    archives = list(output.glob("*.tar.gz"))
    assert bool(archives) == success, name
    if message:
        assert message.encode() in result, result.decode()
    print(name, "PASS", flush=True)
    return archives[0] if success else None


print("Disposable fixture:", base, flush=True)
for name in ("apps", "libs", "docs", "skills"):
    shutil.copytree(source / name, repo / name,
                    ignore=shutil.ignore_patterns(".zig-cache", "zig-out"))
shutil.copy2(source / "README.md", repo / "README.md")
(repo / ".gitignore").write_text(".zig-cache/\nzig-out/\nNOTICE\nignored-source.zig\nLICENSE\n")
(repo / "LICENSE").write_text("NON-LICENSE TEST SENTINEL. Not approved terms. Never distribute.\n")
run(["git", "init", "--initial-branch=fixture"])
run(["git", "config", "user.name", "Packaging fixture"])
run(["git", "config", "user.email", "fixture@localhost"])
run(["git", "add", "."])
run(["git", "add", "--force", "LICENSE"])
run(["git", "commit", "-m", "Synthetic packaging fixture; not an approved candidate"])
head = run(["git", "rev-parse", "HEAD"]).decode().strip()

for name in ("NOTICE", "apps/cli/src/ignored-source.zig", "untracked.txt"):
    path = repo / name
    path.write_text("Uncommitted input must not be packaged.\n")
    package("reject-" + path.name, message="clean checkout" if name == "untracked.txt"
            else "including ignored inputs")
    path.unlink()

readme = (repo / "README.md").read_bytes()
(repo / "README.md").write_bytes(readme + b"\nDirty metadata.\n")
package("reject-dirty", message="clean checkout")
(repo / "README.md").write_bytes(readme)
# Generated ignored caches may exist, but release builds must not borrow their contents.
(repo / "apps/cli/.zig-cache").mkdir()
(repo / "apps/cli/.zig-cache/untrusted").write_text("Not a release input.\n")
first = package("clean-release", True)

# Git status hides these edits. The committed export must still supply every package input.
paths = ["README.md", "libs/core/src/root.zig"]
run(["git", "update-index", "--skip-worktree", "--", *paths])
for name in paths:
    (repo / name).write_text("UNCOMMITTED SKIP-WORKTREE CONTENT\n")
assert run(["git", "status", "--porcelain"]) == b""
second = package("skip-worktree-release", True)
with tarfile.open(first) as archive, tarfile.open(second) as repeated:
    prefix = archive.getnames()[0]
    assert archive.extractfile(prefix + "/README.md").read() == readme
    assert repeated.extractfile(prefix + "/README.md").read() == readme
    assert ("source_head=" + head).encode() in repeated.extractfile(prefix + "/BUILD.txt").read()
    assert b"NON-LICENSE TEST SENTINEL" in repeated.extractfile(prefix + "/LICENSE").read()
    assert all(not n.endswith("/NOTICE") for n in repeated.getnames())
run(["git", "update-index", "--no-skip-worktree", "--", *paths])
for name in paths:
    (repo / name).write_bytes(run(["git", "show", "HEAD:" + name]))

run(["git", "rm", "--cached", "LICENSE"])
run(["git", "commit", "-m", "Fixture omits license from committed inventory"])
package("reject-ignored-license", message="including ignored inputs")
(repo / "LICENSE").unlink()
package("reject-missing-license", message="committed LICENSE required")
(repo / "LICENSE").symlink_to(base / "outside-license")
(base / "outside-license").write_text("NON-LICENSE outside export\n")
run(["git", "add", "--force", "LICENSE"])
run(["git", "commit", "-m", "Fixture has external source symlink"])
package("reject-symlink", message="source symlinks are unsupported")
print("All native packaging gates PASS; evidence:", base, flush=True)
