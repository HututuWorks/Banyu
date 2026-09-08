#!/usr/bin/env python3
"""Compile isolated copies of the App for native Mac Catalyst visual review.

Run through scripts/test-app-ui.sh. No production source is changed. The review
uses in-memory settings, blocks cloud transports, and stubs Apple availability.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def replace_body(text, signature, replacement):
    """Replace one known method in a disposable copy; fail if it disappears."""
    if text.count(signature) != 1:
        raise ValueError(f'Expected exactly one review injection site: {signature}')
    start = text.index(signature)
    brace = text.index('{', start)
    level, end = 1, brace + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[:brace] + replacement + text[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arch', required=True, choices=('arm64', 'x86_64'))
    args = parser.parse_args()
    root, output = args.root.resolve(), args.output.resolve()
    tests = root / 'Tests/AppUI'
    copied = output / 'Sources'
    app = output / 'BanyuAppReview.app'
    macos, resources = app / 'Contents/MacOS', app / 'Contents/Resources'
    for directory in (copied, macos, resources):
        directory.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    paths, manifest = [], []
    source_files = sorted((root / 'Shared').glob('*.swift')) + sorted((root / 'App').rglob('*.swift'))
    for path in source_files:
        text = path.read_text()
        relative = path.relative_to(root)
        manifest.append({'path': str(relative), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
        if path.name == 'EnglishHintKeyboardApp.swift':
            continue
        if path.name == 'TranslationSettings.swift':
            if text.count('static let shared = TranslationSettingsStore()') != 1 or \
               text.count('= KeychainTranslationSettingsPersistence()') != 1:
                raise ValueError('Settings construction changed; review memory injection before running')
            text = text.replace('static let shared = TranslationSettingsStore()',
                                'static let shared = TranslationSettingsStore(persistence: PreviewSettingsPersistence.shared)')
            text = text.replace('= KeychainTranslationSettingsPersistence()', '= PreviewSettingsPersistence.shared')
        if path.name in ('QwenTranslator.swift', 'SentenceAnalyzer.swift'):
            response = 'QwenTransportResponse' if path.name == 'QwenTranslator.swift' else 'SentenceAnalysisTransportResponse'
            text = replace_body(text, f'func send(_ request: URLRequest) async throws -> {response} {{',
                                '{ throw URLError(.notConnectedToInternet) }')
        if path.name == 'QwenSpeechSynthesizer.swift':
            text = replace_body(text,
                                'func send(_ request: URLRequest, maximumBytes: Int) async throws -> QwenSpeechResponse {',
                                '{ throw URLError(.notConnectedToInternet) }')
        if path.name == 'AppleLanguagePacksView.swift':
            text = replace_body(text, 'private func refreshStatus(for language: TranslationLanguage) async',
                                '{ isInstalled = true; statusText = "\\(language.name) → 英文已就绪" }')
            modifier = '.translationTask(configuration, action: preparationAction(request: requestID, language: selected))'
            if text.count(modifier) != 1:
                raise ValueError('Expected one Apple translation task to disable in review copy')
            text = text.replace(modifier, '')
        target = copied / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        paths.append(target)
    for license_file in (root / 'Licenses').glob('*.txt'):
        shutil.copy2(license_file, resources / license_file.name)
    assets = root / 'App/Assets.xcassets'
    for asset in sorted(p for p in assets.rglob('*') if p.is_file()):
        manifest.append({'path': str(asset.relative_to(root)), 'sha256': hashlib.sha256(asset.read_bytes()).hexdigest()})
    with (output / 'assets-build.log').open('w') as log:
        subprocess.run(['xcrun', 'actool', str(assets), '--compile', str(resources),
                        '--platform', 'macosx', '--target-device', 'ipad',
                        '--minimum-deployment-target', '26.0', '--output-format', 'human-readable-text'],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
    info = {
        'CFBundleIdentifier': 'com.example.BanyuAppUIReview',
        'CFBundleName': '伴语本地界面检查', 'CFBundleDisplayName': '伴语本地界面检查',
        'CFBundleExecutable': 'BanyuAppReview', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': 'UI Review', 'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '26.0', 'NSHighResolutionCapable': True,
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'NSHumanReadableCopyright': 'Native Mac Catalyst review, not an iPhone screenshot; memory-only settings; network blocked',
    }
    with (app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump(info, stream)
    command = ['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6', '-parse-as-library',
               '-target', f'{args.arch}-apple-ios26.0-macabi', '-sdk', sdk,
               '-module-cache-path', str(output / 'ModuleCache'),
               '-F', str(Path(sdk) / 'System/iOSSupport/System/Library/Frameworks'),
               '-framework', 'UIKit', *map(str, paths), *map(str, sorted(tests.glob('*.swift'))),
               '-o', str(macos / 'BanyuAppReview')]
    with (output / 'compile.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    (output / 'source-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    environment = dict(os.environ, BANYU_REVIEW_OUTPUT=str(output))
    with (output / 'render.log').open('w') as log:
        subprocess.run([str(macos / 'BanyuAppReview')], env=environment,
                       check=True, stdout=log, stderr=subprocess.STDOUT)
    print((output / 'render.log').read_text())
    print(f'Native App UI report: {output / "app-verification.json"}')


if __name__ == '__main__':
    main()
