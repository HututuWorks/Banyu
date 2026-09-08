#!/usr/bin/env python3
"""Check distributable files and the generated Xcode project without building.

Uses Python's standard library, git and macOS plutil. Before git init, an isolated
temporary index applies this repository's .gitignore. Once initialized, tracked
files are checked even if subsequently ignored. Credentials are never printed.
This is a conservative preflight, not a guarantee that arbitrary secrets cannot
exist; keep real credentials out of source and use GitHub secret scanning too.
"""
from __future__ import annotations

import ast
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
PROJECT = "EnglishHintKeyboard.xcodeproj/project.pbxproj"
ASSETS = "App/Assets.xcassets"
APP = "EnglishHintKeyboard"
# These identities must survive regeneration and layout changes.
TARGETS = {
    APP: ("8C1A045E96B998B40533C7FF", "com.tutuhu.EnglishHintKeyboard", None),
    "EnglishHintKeyboardExtension": (
        "82F876CF2687B22D6A4DB42E", "com.tutuhu.EnglishHintKeyboard.Keyboard", "qwerty"),
    "EnglishHintNineKeyExtension": (
        "80EBB8070CF9C3C481DE55E4", "com.tutuhu.EnglishHintKeyboard.NineKey", "nineKey"),
}
REQUIRED = {
    PROJECT, ".gitignore", ".github/workflows/ci.yml", "README.md", "AGENTS.md",
    "CHANGELOG.md", "docs/AUDIT.md", "docs/ARCHITECTURE.md", "docs/DEVELOPMENT.md",
    "docs/TESTING.md", "docs/PRIVACY.md", "docs/KNOWN_ISSUES.md",
    "Config/Signing.xcconfig", "Config/Local.xcconfig.example",
    "Config/Translation.entitlements", "App/EnglishHintKeyboardApp.swift",
    "Keyboard/KeyboardViewController.swift", "Keyboard/PinyinDecoder.mm",
    "Shared/LiveHintCore.swift", "Shared/TranslationSettings.swift",
    "Resources/dict_pinyin.dat", "THIRD_PARTY_NOTICES.md",
    "Licenses/AOSP-Pinyin-NOTICE.txt", "Licenses/translatekb-LICENSE.txt",
    "Vendor/AOSPPinyin/NOTICE", "Vendor/AOSPPinyin/UPSTREAM.json",
    "Vendor/AOSPPinyin/README.integration.md", "scripts/generate-project.py",
    "scripts/common.sh", "scripts/test.sh", "scripts/xcode-project.sh",
    f"{ASSETS}/AppIcon.appiconset/Contents.json",
    f"{ASSETS}/BrandLogo.imageset/Contents.json",
}
SECRET_PATTERNS = {
    "API credential": re.compile(rb"\bsk-[A-Za-z0-9._-]{30,}"),
    "GitHub credential": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})"),
    "private key": re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----"),
}
ERRORS: list[str] = []
HAS_GIT_INDEX = False


def error(path: str, message: str, line: int | None = None) -> None:
    location = f"{path}:{line}" if line else path
    ERRORS.append(f"{location}: {message}")


def run(command: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=ROOT, capture_output=True, check=False)


def candidate_files() -> set[str]:
    """Include tracked + untracked nonignored files, without global ignore rules."""
    global HAS_GIT_INDEX
    git = ["git", "-c", "core.excludesFile=/dev/null"]
    existing = run(git + ["rev-parse", "--show-toplevel"])
    if existing.returncode == 0 and Path(existing.stdout.decode().strip()).resolve() == ROOT:
        HAS_GIT_INDEX = True
        result = run(git + ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    else:
        with tempfile.TemporaryDirectory(prefix="banyu-repository-check-") as directory:
            initialized = run(git + ["init", "--bare", "--quiet", directory])
            if initialized.returncode:
                raise RuntimeError("Could not create isolated Git index")
            result = run(git + [f"--git-dir={directory}", f"--work-tree={ROOT}",
                                "ls-files", "--others", "--exclude-standard", "-z"])
    if result.returncode:
        raise RuntimeError("Could not enumerate distributable files with Git")
    return {value.decode("utf-8") for value in result.stdout.split(b"\0") if value}


def check_credentials(relative: str, data: bytes, *, staged: bool = False) -> None:
    prefix = "staged version: " if staged else ""
    for category, pattern in SECRET_PATTERNS.items():
        for match in pattern.finditer(data):
            error(relative, f"{prefix}possible {category}; inspect locally (value redacted)",
                  data.count(b"\n", 0, match.start()) + 1)
    if Path(relative).suffix == ".xcconfig":
        for number, line in enumerate(data.decode("utf-8").splitlines(), 1):
            if re.match(r"\s*(?:DEVELOPMENT_TEAM|PROVISIONING_PROFILE(?:_SPECIFIER)?)\s*=\s*\S", line):
                error(relative, f"{prefix}personal signing belongs in ignored Config/Local.xcconfig", number)


def forbidden_path(relative: str) -> bool:
    path = PurePosixPath(relative)
    return (
        path.parts[0] in {"build", "outputs", ".local", "sources", "references", "downloads"}
        or ".git" in path.parts or "xcuserdata" in path.parts or "__pycache__" in path.parts
        or relative == "Config/Local.xcconfig" or path.name == ".DS_Store"
        or (path.name.startswith(".env") and path.name != ".env.example")
        or any(part.endswith((".app", ".appex", ".dSYM")) for part in path.parts)
        or path.suffix.lower() in {".ipa", ".pyc", ".xcuserstate", ".mobileprovision", ".p12", ".cer", ".key", ".log"}
    )


def check_files(files: set[str]) -> None:
    for required in sorted(REQUIRED - files):
        error(required, "required distributable file is missing or ignored")
    for relative in sorted(files):
        path = ROOT / relative
        if forbidden_path(relative):
            error(relative, "local state, historical files or generated products must not be distributed")
            continue
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT):
            error(relative, "symlinks and paths outside the repository are not supported")
            continue
        if not path.is_file():
            error(relative, "candidate is not a regular file; stage removals before checking")
            continue
        if path.stat().st_size > 5 * 1024 * 1024:
            error(relative, "file exceeds the 5 MiB source/resource budget")
            continue
        check_credentials(relative, path.read_bytes())
    if HAS_GIT_INDEX:
        # A sanitized working copy must not hide a credential still in the index.
        changed = run(["git", "diff", "--name-only", "--diff-filter=ACMRT", "-z"])
        if changed.returncode:
            raise RuntimeError("Cannot compare index and working files")
        for value in changed.stdout.split(b"\0"):
            if value:
                relative = value.decode("utf-8")
                indexed = run(["git", "show", f":{relative}"])
                if indexed.returncode:
                    error(relative, "could not check staged version; resolve index conflicts")
                else:
                    check_credentials(relative, indexed.stdout, staged=True)


def generator_versions() -> dict[str, str]:
    tree = ast.parse((ROOT / "scripts/generate-project.py").read_text())
    names = {"BUILD_VERSION", "MARKETING_VERSION"}
    values = {target.id: ast.literal_eval(node.value)
              for node in tree.body if isinstance(node, ast.Assign)
              for target in node.targets if isinstance(target, ast.Name) and target.id in names}
    if values.keys() != names or not all(isinstance(value, str) and value for value in values.values()):
        raise RuntimeError("Generator version constants are missing or invalid")
    return values


def check_project(files: set[str]) -> None:
    converted = run(["/usr/bin/plutil", "-convert", "json", "-o", "-", PROJECT])
    if converted.returncode:
        raise RuntimeError("Cannot parse Xcode project with plutil")
    document = json.loads(converted.stdout)
    objects = document["objects"]
    project = objects[document["rootObject"]]
    versions = generator_versions()
    references: dict[str, str] = {}

    def walk(identifier: str, parent: Path, ancestors: frozenset[str]) -> None:
        if identifier in ancestors:
            error(PROJECT, "cyclic project group reference")
            return
        item = objects[identifier]
        if item.get("sourceTree") == "BUILT_PRODUCTS_DIR":
            return
        tree = item.get("sourceTree", "<group>")
        if tree not in {"<group>", "SOURCE_ROOT"}:
            error(PROJECT, "nonportable source reference")
            return
        base = ROOT if tree == "SOURCE_ROOT" else parent
        path = base / item.get("path", "")
        if not path.resolve().is_relative_to(ROOT):
            error(PROJECT, "source reference escapes repository")
            return
        if item["isa"] == "PBXGroup":
            for child in item.get("children", []):
                walk(child, path, ancestors | {identifier})
        elif item["isa"] == "PBXFileReference":
            relative = path.relative_to(ROOT).as_posix()
            references[identifier] = relative
            if not path.exists() or (path.is_file() and relative not in files):
                error(relative, "project references a missing or undistributed file")

    walk(project["mainGroup"], ROOT, frozenset())
    for item in objects.values():
        if item.get("isa") == "XCBuildConfiguration":
            settings = item.get("buildSettings", {})
            if any(key in settings for key in ("DEVELOPMENT_TEAM", "PROVISIONING_PROFILE", "PROVISIONING_PROFILE_SPECIFIER")):
                error(PROJECT, "personal signing is embedded in generated build settings")

    def configurations(owner: dict) -> dict[str, dict]:
        return {objects[key]["name"]: objects[key]
                for key in objects[owner["buildConfigurationList"]]["buildConfigurations"]}

    common = configurations(project)
    for configuration in common.values():
        if references.get(configuration.get("baseConfigurationReference")) != "Config/Signing.xcconfig":
            error(PROJECT, "project configuration must use portable signing include")
    native = {item["name"]: (key, item) for key, item in objects.items() if item.get("isa") == "PBXNativeTarget"}
    if set(native) != set(TARGETS) or set(project["targets"]) != {identity[0] for identity in TARGETS.values()}:
        error(PROJECT, "expected exactly the app and two stable keyboard targets")
    embedded = set()
    for name, (expected_id, bundle_id, layout) in TARGETS.items():
        if name not in native:
            continue
        identifier, target = native[name]
        if identifier != expected_id:
            error(PROJECT, f"{name}: target identity changed")
        target_configs = configurations(target)
        if set(target_configs) != {"Debug", "Release"}:
            error(PROJECT, f"{name}: expected Debug and Release configurations")
        for mode, config in target_configs.items():
            settings = {**common[mode]["buildSettings"], **config["buildSettings"]}
            for setting, expected in (("PRODUCT_BUNDLE_IDENTIFIER", bundle_id),
                                      ("CURRENT_PROJECT_VERSION", versions["BUILD_VERSION"]),
                                      ("MARKETING_VERSION", versions["MARKETING_VERSION"])):
                if settings.get(setting) != expected:
                    error(PROJECT, f"{name}/{mode}: {setting} is inconsistent")
            info_path = settings["INFOPLIST_FILE"]
            with (ROOT / info_path).open("rb") as stream:
                info = plistlib.load(stream)
            if info.get("CFBundleVersion") != versions["BUILD_VERSION"] or info.get("CFBundleShortVersionString") != versions["MARKETING_VERSION"]:
                error(info_path, "version does not match generator")
            if layout:
                if info.get("EHKKeyboardLayout") != layout or info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.keyboard-service":
                    error(info_path, "keyboard entry or fixed layout is inconsistent")
            elif settings.get("ASSETCATALOG_COMPILER_APPICON_NAME") != "AppIcon":
                error(PROJECT, f"{name}/{mode}: AppIcon is not configured")
        sources, resources = set(), set()
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            for build_id in phase.get("files", []):
                reference = objects[build_id]["fileRef"]
                if phase["isa"] == "PBXSourcesBuildPhase":
                    sources.add(references[reference])
                elif phase["isa"] == "PBXResourcesBuildPhase":
                    resources.add(references[reference])
                elif name == APP and phase["isa"] == "PBXCopyFilesBuildPhase":
                    embedded.add(reference)
        if layout:
            expected_sources = {path for path in files if (
                path.startswith(("Keyboard/", "Shared/")) and Path(path).suffix in {".swift", ".mm"})
                or (path.startswith("Vendor/AOSPPinyin/jni/share/") and path.endswith(".cpp"))}
            if not {"Resources/dict_pinyin.dat", "Licenses/AOSP-Pinyin-NOTICE.txt"} <= resources:
                error(PROJECT, f"{name}: dictionary or license is not packaged")
        else:
            expected_sources = {path for path in files if path.startswith(("App/", "Shared/")) and path.endswith(".swift")}
            if ASSETS not in resources:
                error(PROJECT, "App assets are not packaged")
        if sources != expected_sources:
            error(PROJECT, f"{name}: source membership differs from production directories; regenerate project")
    expected_products = {native[name][1]["productReference"] for name in TARGETS if name != APP and name in native}
    if embedded != expected_products:
        error(PROJECT, "App must embed both keyboard products")


def check_assets(files: set[str]) -> None:
    for asset in ("AppIcon.appiconset", "BrandLogo.imageset"):
        directory = f"{ASSETS}/{asset}"
        manifest = json.loads((ROOT / directory / "Contents.json").read_text())
        images = [image for image in manifest["images"] if image.get("filename")]
        if not images:
            error(directory, "asset contains no image")
        for image in images:
            relative = f"{directory}/{image['filename']}"
            if relative not in files:
                error(relative, "asset image is missing or ignored")
                continue
            data = (ROOT / relative).read_bytes()
            if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
                error(relative, "expected valid PNG asset")
                continue
            width, height, _, color = struct.unpack(">IIBB", data[16:26])
            if asset == "AppIcon.appiconset":
                if (width, height) != (1024, 1024):
                    error(relative, "AppIcon must be 1024 × 1024")
                # Current source is opaque RGB; reject alpha-bearing replacements.
                if color not in {0, 2}:
                    error(relative, "AppIcon must use opaque RGB or grayscale PNG")


def check_links(files: set[str]) -> None:
    patterns = [re.compile(r"!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s)]+)"),
                re.compile(r"^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)", re.MULTILINE),
                re.compile(r"\b(?:src|href)=[\"']([^\"']+)[\"']")]
    for relative in sorted(path for path in files if path.endswith(".md")):
        source = (ROOT / relative).read_text()
        # Ignore code examples while retaining line numbers for diagnostics.
        source = re.sub(r"^\s*```[^\n]*\n.*?^\s*```[^\n]*", lambda match: "\n" * match[0].count("\n"), source, flags=re.MULTILINE | re.DOTALL)
        for pattern in patterns:
            for match in pattern.finditer(source):
                destination = match[1].strip("<>")
                url = urlsplit(destination)
                if url.scheme or url.netloc or not url.path:
                    continue
                path = unquote(url.path)
                resolved = (ROOT / path.lstrip("/") if path.startswith("/") else ROOT / Path(relative).parent / path).resolve()
                if not resolved.is_relative_to(ROOT) or not resolved.exists():
                    error(relative, "local documentation link is missing or outside repository",
                          source.count("\n", 0, match.start()) + 1)


def main() -> int:
    try:
        files = candidate_files()
        check_files(files)
        for checker in (check_project, check_assets, check_links):
            try:
                checker(files)
            except (KeyError, ValueError, OSError, RuntimeError, SyntaxError, struct.error):
                # Parser errors may include source data; never print raw exceptions.
                error(checker.__name__, "could not validate malformed or missing repository data")
    except (OSError, RuntimeError, UnicodeError):
        error("repository", "could not enumerate or read repository files")
        files = set()
    for message in ERRORS:
        print(f"ERROR {message}", file=sys.stderr)
    if ERRORS:
        print(f"Repository check failed: {len(ERRORS)} issue(s).", file=sys.stderr)
        return 1
    print(f"Repository check passed: {len(files)} distributable files; stable App + 26-key + nine-key targets, assets, versions, links and credential preflight.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
