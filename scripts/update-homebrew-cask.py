#!/usr/bin/env python3
"""Validate the UseMac Homebrew cask or update its version and DMG checksum."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
STABLE_VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
PRERELEASE = r"-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*"
SHA256 = r"[0-9a-fA-F]{64}"
REQUIRED_LINES = (
    'cask "usemac" do',
    'url "https://usemac.app/downloads/usemac-#{version}-arm64.dmg"',
    "auto_updates true",
    "depends_on arch: :arm64",
    'depends_on macos: ">= :sequoia"',
    'app "UseMac.app"',
    'binary "#{appdir}/UseMac.app/Contents/Helpers/usemac"',
)


def field(source: str, name: str):
    matches = list(re.finditer(rf'^[ \t]*{name}[ \t]+"([^"\r\n]*)"[ \t]*\r?$', source, re.M))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {name} declaration")
    return matches[0]


def validate(source: str, version: str, sha256: str, allow_prerelease: bool) -> None:
    version_pattern = STABLE_VERSION + (rf"(?:{PRERELEASE})?" if allow_prerelease else "")
    if not re.fullmatch(version_pattern, version):
        raise ValueError(f"invalid version {version!r}; expected a stable numeric version (X.Y.Z)")
    if not re.fullmatch(SHA256, sha256):
        raise ValueError("invalid sha256; expected exactly 64 hexadecimal characters")

    lines = {line.strip() for line in source.splitlines()}
    for required in REQUIRED_LINES:
        if required not in lines:
            raise ValueError(f"missing cask stanza: {required}")

    result = subprocess.run(["ruby", "-c"], input=source, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f"ruby -c failed: {result.stderr.strip()}")


def check_sums(path: Path, version: str, sha256: str) -> None:
    filename = f"usemac-{version}-arm64.dmg"
    entry = rf"({SHA256})[ \t]+\*?{re.escape(filename)}"
    hashes = re.findall(rf"^{entry}$", path.read_text(), re.M)
    if len(hashes) != 1:
        raise ValueError(f"{path}: expected exactly one SHA256SUMS entry for {filename}")
    if hashes[0].lower() != sha256.lower():
        raise ValueError(f"{path}: SHA256SUMS mismatch for {filename}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cask", type=Path, nargs="?", default=ROOT / "Casks/usemac.rb")
    parser.add_argument("--version")
    parser.add_argument("--sha256")
    parser.add_argument("--allow-prerelease", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--expect-version")
    parser.add_argument("--sums-file", type=Path)
    args = parser.parse_args()

    if args.check:
        if args.version is not None or args.sha256 is not None:
            parser.error("--check cannot be combined with --version or --sha256")
    elif args.version is None or args.sha256 is None:
        parser.error("updating requires --version and --sha256")
    elif args.expect_version is not None or args.sums_file is not None:
        parser.error("--expect-version and --sums-file require --check")

    try:
        source = args.cask.read_bytes().decode("utf-8")
        version_field = field(source, "version")
        sha256_field = field(source, "sha256")
        if args.check:
            version = version_field[1]
            sha256 = sha256_field[1]
            validate(source, version, sha256, args.allow_prerelease)
            if args.expect_version is not None and args.expect_version != version:
                raise ValueError(f"expected version {args.expect_version}, found {version}")
            sums = args.sums_file or ROOT / "dist" / f"usemac-{version}-SHA256SUMS.txt"
            if args.sums_file is not None or sums.exists():
                check_sums(sums, version, sha256)
            print(f"{args.cask}: OK ({version})")
        else:
            version = args.version
            sha256 = args.sha256.lower()
            updated = source
            edits = [(version_field.span(1), version), (sha256_field.span(1), sha256)]
            for (start, end), value in sorted(edits, reverse=True):
                updated = updated[:start] + value + updated[end:]
            validate(updated, version, sha256, args.allow_prerelease)
            if updated != source:
                args.cask.write_bytes(updated.encode("utf-8"))
            print(f"{args.cask}: {version} ({sha256})")
    except (OSError, ValueError) as error:
        parser.exit(1, f"{args.cask}: {error}\n")


if __name__ == "__main__":
    main()
