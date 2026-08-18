from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
RELEASE_SCRIPT = ROOT / "scripts" / "release.sh"
INSTALL_SCRIPT = ROOT / "run.sh"


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )


def _release_repo(tmp_path: Path, branch: str) -> tuple[Path, dict[str, str]]:
    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    (repo / "turnstone").mkdir()
    shutil.copy2(RELEASE_SCRIPT, repo / "scripts" / "release.sh")
    (repo / "pyproject.toml").write_text('[project]\nversion = "1.8.0"\n')
    (repo / "turnstone" / "__init__.py").write_text('__version__ = "1.8.0"\n')
    (repo / "uv.lock").write_text("version = 1\n")

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_uv = fake_bin / "uv"
    fake_uv.write_text("#!/usr/bin/env bash\nexit 0\n")
    fake_uv.chmod(0o755)

    _git(repo, "init", "--initial-branch=main")
    _git(repo, "config", "user.name", "Release Test")
    _git(repo, "config", "user.email", "release-test@example.com")
    _git(repo, "add", "pyproject.toml", "scripts/release.sh", "turnstone/__init__.py", "uv.lock")
    _git(repo, "commit", "-m", "initial")
    if branch != "main":
        _git(repo, "switch", "-c", branch)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    return repo, env


def _run_release(repo: Path, env: dict[str, str], version: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "scripts/release.sh", version],
        cwd=repo,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )


@pytest.mark.parametrize(
    ("branch", "version"),
    [
        ("main", "1.8.1"),
        ("dev", "1.9.0a1"),
        ("stable/1.8", "1.8.2"),
    ],
)
def test_release_script_accepts_version_for_branch(
    tmp_path: Path,
    branch: str,
    version: str,
) -> None:
    repo, env = _release_repo(tmp_path, branch)

    result = _run_release(repo, env, version)

    assert result.returncode == 0, result.stderr
    assert _git(repo, "tag", "--points-at", "HEAD").stdout.strip() == f"v{version}"
    assert f'version = "{version}"' in (repo / "pyproject.toml").read_text()
    assert f'__version__ = "{version}"' in (repo / "turnstone" / "__init__.py").read_text()
    assert _git(repo, "status", "--porcelain").stdout == ""


@pytest.mark.parametrize(
    ("branch", "version", "message"),
    [
        ("main", "1.9.0rc1", "pre-releases must be cut from dev"),
        ("dev", "1.9.0", "stable releases must be cut from main"),
        ("stable/1.8", "1.8.2rc1", "pre-releases must be cut from dev"),
        ("stable/1.7", "1.8.1", "1.8.1 belongs on stable/1.8"),
        ("feature/release", "1.8.1", "releases must be cut from main, dev, or stable/X.Y"),
    ],
)
def test_release_script_rejects_wrong_branch_without_mutation(
    tmp_path: Path,
    branch: str,
    version: str,
    message: str,
) -> None:
    repo, env = _release_repo(tmp_path, branch)
    before = _git(repo, "rev-parse", "HEAD").stdout.strip()

    result = _run_release(repo, env, version)

    assert result.returncode == 1
    assert message in result.stderr
    assert _git(repo, "rev-parse", "HEAD").stdout.strip() == before
    assert _git(repo, "status", "--porcelain").stdout == ""
    assert _git(repo, "tag").stdout == ""


def test_release_script_rejects_detached_head(tmp_path: Path) -> None:
    repo, env = _release_repo(tmp_path, "main")
    _git(repo, "switch", "--detach")

    result = _run_release(repo, env, "1.8.1")

    assert result.returncode == 1
    assert "releases must be cut from a branch, not detached HEAD" in result.stderr
    assert _git(repo, "status", "--porcelain").stdout == ""
    assert _git(repo, "tag").stdout == ""


def test_installer_defaults_new_clones_to_stable_main() -> None:
    script = INSTALL_SCRIPT.read_text()

    assert 'SOURCE_BRANCH="${TURNSTONE_BRANCH:-main}"' in script
    assert 'git clone --depth 1 --branch "$SOURCE_BRANCH" "$REPO_URL" "$INSTALL_DIR"' in script
