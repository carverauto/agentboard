#!/usr/bin/env python3
"""Build the CLI offline using only Dockerfile.cli's build-stage COPY inputs.

Run on a disposable Linux build host with Go and cached module dependencies:
    python3 build/integration/cli_docker_inputs_test.py [--root REPOSITORY]

This checks source packaging, including go:embed inputs, without Docker. It is
not an image build or runtime smoke test. The small manifest parser deliberately
rejects unsupported syntax instead of silently approximating a changed recipe.
"""

import argparse
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


class ManifestError(ValueError):
    pass


def ignore_rules(contents):
    """Support root-relative globs, ** directory segments, and ordered ! rules."""
    rules = []
    for raw in contents.lstrip("\ufeff").splitlines():
        pattern = raw.strip()
        if not pattern or pattern.startswith("#"):
            continue
        include = pattern.startswith("!")
        pattern = pattern.removeprefix("!").strip("/")
        if pattern == ".":
            continue
        if (not pattern or re.search(r"[\s\\\[\]!]", pattern)
                or any(part in ("", ".", "..") for part in pattern.split("/"))):
            raise ManifestError(f"Unsupported .dockerignore pattern: {raw!r}")
        parts = pattern.split("/")
        regex = ""
        for index, part in enumerate(parts):
            if part == "**":
                regex += ".*" if index == len(parts) - 1 else "(?:[^/]+/)*"
                continue
            if "**" in part:
                raise ManifestError(f"Unsupported .dockerignore pattern: {raw!r}")
            regex += "".join("[^/]*" if char == "*" else "[^/]" if char == "?"
                             else re.escape(char) for char in part)
            if index < len(parts) - 1:
                regex += "/"
        # A matching directory excludes descendants too. Later exceptions can
        # re-include files under it, so staging must still traverse that directory.
        rules.append((re.compile("^" + regex + "(?:/|$)"), include))
    return rules


def included(path, rules):
    result = True
    for pattern, include in rules:
        if pattern.match(path):
            result = include
    return result


def instructions(contents):
    pending = ""
    for raw in contents.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        line = pending + line
        pending = ""
        name, _, value = line.partition(" ")
        yield name.upper(), value.strip()
    if pending:
        raise ManifestError("Unterminated Dockerfile.cli continuation")


def relative_path(value):
    path = PurePosixPath(value)
    if (path.is_absolute() or ".." in path.parts or value.startswith("--")
            or re.search(r"[\s*$?\[\]{}\\;|&<>`\"']", value)):
        raise ManifestError(f"Unsupported COPY path: {value!r}")
    return path


def copy_input(root, stage, source, destination, rules):
    source_path = root / relative_path(source)
    destination_path = stage / relative_path(destination)
    if source_path.is_symlink() or not source_path.exists():
        raise ManifestError(f"Missing or unsupported COPY source: {source}")
    if any(parent.is_symlink() for parent in source_path.parents if parent != root):
        raise ManifestError(f"Symlinked COPY source is unsupported: {source}")
    if source_path.is_dir():
        candidates = sorted(source_path.rglob("*"))
    else:
        candidates = [source_path]
        if destination.endswith("/") or destination_path.is_dir():
            destination_path /= source_path.name
    copied = 0
    for candidate in candidates:
        relative = candidate.relative_to(root).as_posix()
        if candidate.is_symlink():
            raise ManifestError(f"Symlinked COPY input is unsupported: {relative}")
        if candidate.is_dir() or not included(relative, rules):
            continue
        if not candidate.is_file():
            raise ManifestError(f"Non-regular COPY input is unsupported: {relative}")
        target = (destination_path / candidate.relative_to(source_path)
                  if source_path.is_dir() else destination_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(candidate, target)
        copied += 1
    if not copied:
        raise ManifestError(f"COPY source excluded by .dockerignore or empty: {source}")
    return copied


def stage_inputs(root, stage, dockerfile, dockerignore, output):
    rules = ignore_rules(dockerignore)
    in_build = False
    workdir_seen = False
    command = None
    copied = 0
    for name, value in instructions(dockerfile):
        if name == "FROM":
            if in_build:
                break
            in_build = shlex.split(value)[-2:] == ["AS", "build"]
            continue
        if not in_build or name == "ARG":
            continue
        if name == "WORKDIR" and value == "/src" and not workdir_seen:
            workdir_seen = True
        elif name == "COPY" and workdir_seen and command is None:
            if value.startswith("["):
                raise ManifestError("JSON COPY syntax is unsupported")
            paths = shlex.split(value)
            if len(paths) < 2 or (len(paths) > 2 and not paths[-1].endswith("/")):
                raise ManifestError(f"Unsupported COPY instruction: {value}")
            for source in paths[:-1]:
                copied += copy_input(root, stage, source, paths[-1], rules)
        elif name == "RUN" and value == "go mod download":
            # Dependencies must already be cached; never download in this test.
            continue
        elif name == "RUN" and command is None:
            words = shlex.split(value)
            prefix = ["CGO_ENABLED=0", "GOOS=${TARGETOS:-linux}",
                      "GOARCH=${TARGETARCH:-amd64}", "go", "build"]
            if words[:5] != prefix or any(re.search(r"[$;|&<>`]", word) for word in words[5:]):
                raise ManifestError(f"Unsupported build RUN instruction: {value}")
            command = words[3:]
            if (command.count("-o") != 1 or command[-1] != "./cmd/agentboard"
                    or command.index("-o") + 1 >= len(command)
                    or command[command.index("-o") + 1] != "/out/agentboard"):
                raise ManifestError(f"Unsupported build output/target: {value}")
            command[command.index("-o") + 1] = str(output)
        else:
            raise ManifestError(f"Unsupported build-stage instruction: {name} {value}")
    if not workdir_seen or not command or not copied:
        raise ManifestError("Expected build stage with WORKDIR /src, COPY inputs, and go build")
    return command, copied


def check(root, dockerfile=None, dockerignore=None):
    if (root / "Dockerfile.cli.dockerignore").exists():
        raise ManifestError("Dockerfile-specific ignore files are unsupported")
    dockerfile = (root / "Dockerfile.cli").read_text() if dockerfile is None else dockerfile
    dockerignore = (root / ".dockerignore").read_text() if dockerignore is None else dockerignore
    with tempfile.TemporaryDirectory(prefix="agentboard-cli-inputs-") as temporary:
        stage = Path(temporary) / "src"
        stage.mkdir()
        output = Path(temporary) / "agentboard"
        command, copied = stage_inputs(root, stage, dockerfile, dockerignore, output)
        # The Docker context has no .git. Disable host-only VCS stamping: Go
        # itself searches above the temporary directory even with Git's ceiling.
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GOPROXY="off", GOSUMDB="off", GOTOOLCHAIN="local", GOWORK="off",
                   GOFLAGS="-buildvcs=false", CGO_ENABLED="0", GOOS="linux", GOARCH="amd64",
                   GIT_CEILING_DIRECTORIES=temporary)
        print(f"Staged {copied} Dockerfile.cli COPY inputs; building offline for linux/amd64.", flush=True)
        subprocess.run(command, cwd=stage, env=env, check=True, timeout=180)
        if not output.is_file() or not output.stat().st_size:
            raise ManifestError("Go build did not produce the expected CLI binary")
        print("PASS: verified offline Go build from staged Dockerfile.cli inputs (not a Docker image build).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        check(args.root.resolve())
    except (ManifestError, OSError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
