#!/usr/bin/env python3
"""Generate one app and two fixed-layout keyboard targets with stable identities."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

APP_DISPLAY_NAME = '伴语'
BUILD_VERSION = '33'
MARKETING_VERSION = '0.1.0'
APP_TARGET_NAME = 'EnglishHintKeyboard'
APP_BUNDLE_IDENTIFIER = 'com.tutuhu.EnglishHintKeyboard'


@dataclass(frozen=True)
class KeyboardTarget:
    scope: str
    name: str
    bundle_identifier: str
    info_file: str
    layout: str
    display_suffix: str


KEYBOARDS = (
    KeyboardTarget('ext', 'EnglishHintKeyboardExtension',
                   APP_BUNDLE_IDENTIFIER + '.Keyboard', 'Keyboard-Info.plist',
                   'qwerty', '26键'),
    KeyboardTarget('ninekey', 'EnglishHintNineKeyExtension',
                   APP_BUNDLE_IDENTIFIER + '.NineKey', 'Keyboard-NineKey-Info.plist',
                   'nineKey', '九宫格'),
)


def read_existing_configuration(project_file):
    """Keep target IDs, selected teams and explicit module names; never bake in a team."""
    if not project_file.exists():
        return {}, {}, {}
    result = subprocess.run(
        ['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project_file)],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise SystemExit('Cannot read existing project; refusing to overwrite signing configuration.')
    try:
        existing = json.loads(result.stdout)['objects']
        teams, target_ids, modules = {}, {}, {}
        for identifier, target in existing.items():
            if target.get('isa') != 'PBXNativeTarget':
                continue
            name = target['name']
            target_ids[name] = identifier
            configurations = existing[target['buildConfigurationList']]['buildConfigurations']
            for config_id in configurations:
                configuration = existing[config_id]
                settings = configuration.get('buildSettings', {})
                key = (name, configuration['name'])
                for setting, destination in [('DEVELOPMENT_TEAM', teams),
                                             ('PRODUCT_MODULE_NAME', modules)]:
                    if setting in settings:
                        value = settings[setting]
                        if not isinstance(value, str):
                            raise ValueError('Unexpected signing/module setting type')
                        destination[key] = value
        return teams, target_ids, modules
    except (KeyError, TypeError, ValueError) as error:
        raise SystemExit('Cannot read target configuration; project has not been regenerated.') from error


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def dump(value, level=0):
    indent = '\t' * level
    if isinstance(value, dict):
        return '{\n' + ''.join(
            '\t' * (level + 1) + json.dumps(str(key), ensure_ascii=False) +
            ' = ' + dump(item, level + 1) + ';\n'
            for key, item in value.items()
        ) + indent + '}'
    if isinstance(value, list):
        return '(' + ', '.join(dump(item, level + 1) for item in value) + ')'
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


def base_info(display_name, package_type):
    return {
        'CFBundleDisplayName': display_name,
        'CFBundleDevelopmentRegion': 'zh_CN',
        'CFBundleExecutable': '$(EXECUTABLE_NAME)',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': '$(PRODUCT_NAME)',
        'CFBundlePackageType': package_type,
        'CFBundleShortVersionString': MARKETING_VERSION,
        'CFBundleVersion': BUILD_VERSION,
        'TranslationKeychainAccessGroup': '$(AppIdentifierPrefix)' + APP_BUNDLE_IDENTIFIER,
    }


def keyboard_info(spec):
    info = base_info(f'{APP_DISPLAY_NAME}·{spec.display_suffix}', 'XPC!')
    info['EHKKeyboardLayout'] = spec.layout
    info['NSExtension'] = {
        'NSExtensionPointIdentifier': 'com.apple.keyboard-service',
        'NSExtensionPrincipalClass': '$(PRODUCT_MODULE_NAME).KeyboardViewController',
        'NSExtensionAttributes': {
            'IsASCIICapable': True,
            'PrefersRightToLeft': False,
            'PrimaryLanguage': 'zh-Hans',
            'RequestsOpenAccess': True,
        },
    }
    return info


def generate(root):
    project = root / 'EnglishHintKeyboard.xcodeproj'
    project_file = project / 'project.pbxproj'
    teams, existing_target_ids, modules = read_existing_configuration(project_file)
    objects, files = {}, {}

    def add(key_name, isa, *, object_id=None, **fields):
        identifier = object_id or uid(key_name)
        if identifier in objects:
            raise ValueError(f'Duplicate project object: {key_name}')
        objects[identifier] = dict(isa=isa, **fields)
        return identifier

    def target_id(scope, name):
        return existing_target_ids.get(name, uid('target:' + scope))

    app_target_id = target_id('app', APP_TARGET_NAME)
    extension_ids = {spec.scope: target_id(spec.scope, spec.name) for spec in KEYBOARDS}

    def file(path, kind):
        identifier = add('file:' + path, 'PBXFileReference', lastKnownFileType=kind,
                         path=path, name=Path(path).name, sourceTree='<group>')
        files[path] = identifier

    def build_file(path, phase_name):
        return add('build:' + phase_name + ':' + path, 'PBXBuildFile', fileRef=files[path])

    def phase(name, kind, entries):
        return add(name, kind, buildActionMask=2147483647, files=entries,
                   runOnlyForDeploymentPostprocessing=0)

    source_groups = (
        ('App', '*.swift', 'sourcecode.swift'),
        ('Tests', '*.swift', 'sourcecode.swift'),
        ('Shared', '*.swift', 'sourcecode.swift'),
        ('Keyboard', '*.swift', 'sourcecode.swift'),
        ('Keyboard', '*.mm', 'sourcecode.cpp.objcpp'),
        ('Keyboard', '*.h', 'sourcecode.c.h'),
        ('Vendor/AOSPPinyin/jni/share', '*.cpp', 'sourcecode.cpp.cpp'),
        ('Vendor/AOSPPinyin/jni/include', '*.h', 'sourcecode.c.h'),
        ('Resources', '*.dat', 'file'),
        ('Licenses', '*.txt', 'text'),
    )
    for folder, pattern, kind in source_groups:
        for path in sorted((root / folder).rglob(pattern)):
            file(str(path.relative_to(root)), kind)
    file('App/Assets.xcassets', 'folder.assetcatalog')
    file('Config/Signing.xcconfig', 'text.xcconfig')
    bridge_header = 'Keyboard/Keyboard-Bridging-Header.h'
    if bridge_header not in files:
        raise SystemExit('Keyboard bridging header is missing; generator does not edit source files.')

    app_info = base_info(APP_DISPLAY_NAME, 'APPL')
    app_info.update({
        'LSRequiresIPhoneOS': True,
        'UILaunchScreen': {},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait',
                                            'UIInterfaceOrientationLandscapeLeft',
                                            'UIInterfaceOrientationLandscapeRight'],
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
    })
    info_files = {'App-Info.plist': app_info}
    info_files.update({spec.info_file: keyboard_info(spec) for spec in KEYBOARDS})
    for filename in info_files:
        file('Config/' + filename, 'text.plist.xml')
    file('Config/Translation.entitlements', 'text.plist.entitlements')

    app_product = add('product:app', 'PBXFileReference', explicitFileType='wrapper.application',
                      includeInIndex=0, path=APP_TARGET_NAME + '.app', sourceTree='BUILT_PRODUCTS_DIR')
    extension_products = {
        spec.scope: add('product:' + spec.scope, 'PBXFileReference',
                        explicitFileType='wrapper.app-extension', includeInIndex=0,
                        path=spec.name + '.appex', sourceTree='BUILT_PRODUCTS_DIR')
        for spec in KEYBOARDS
    }
    products = add('products', 'PBXGroup', children=[app_product] + list(extension_products.values()),
                   name='Products', sourceTree='<group>')
    # Logical groups mirror source directories without changing their relative paths.
    folders = {}
    for path, reference in files.items():
        folder = str(Path(path).parent)
        folders.setdefault(folder, []).append(reference)
        while folder != '.':
            folder = str(Path(folder).parent)
            folders.setdefault(folder, [])
    def source_group(folder):
        children = list(folders[folder])
        subfolders = sorted(f for f in folders if f != folder and str(Path(f).parent) == folder)
        children = [source_group(f) for f in subfolders] + children
        return add('group:source:' + folder, 'PBXGroup', children=children,
                   name=Path(folder).name, sourceTree='<group>')
    top = sorted(f for f in folders if f != '.' and str(Path(f).parent) == '.')
    main_group = add('group:main', 'PBXGroup', children=[source_group(f) for f in top] +
                     folders.get('.', []) + [products], sourceTree='<group>')

    app_source_paths = [path for path in files if path.endswith('.swift') and
                        path.startswith(('App/', 'Shared/'))]
    extension_source_paths = [path for path in files if path.endswith(('.swift', '.mm', '.cpp')) and
                              path.startswith(('Keyboard/', 'Shared/', 'Vendor/'))]
    extension_resource_paths = [path for path in files if path.startswith('Resources/') or
                                path == 'Licenses/AOSP-Pinyin-NOTICE.txt']
    app_sources = phase('app:sources', 'PBXSourcesBuildPhase', [build_file(path, 'app') for path in app_source_paths])
    app_resources = phase('app:resources', 'PBXResourcesBuildPhase',
                          [build_file(path, 'appresources') for path in files if path.startswith('Licenses/') or path.endswith('.xcassets')])
    app_frameworks = phase('app:frameworks', 'PBXFrameworksBuildPhase', [])

    extension_phases, embed_phases, dependencies = {}, [], []
    for spec in KEYBOARDS:
        scope = spec.scope
        sources = phase(scope + ':sources', 'PBXSourcesBuildPhase',
                        [build_file(path, scope) for path in extension_source_paths])
        # Retain the original extension's generated object IDs.
        resource_scope = 'resources' if scope == 'ext' else scope + ':resources'
        resources = phase(scope + ':resources', 'PBXResourcesBuildPhase',
                          [build_file(path, resource_scope) for path in extension_resource_paths])
        frameworks = phase(scope + ':frameworks', 'PBXFrameworksBuildPhase', [])
        extension_phases[scope] = [sources, frameworks, resources]
        prefix = '' if scope == 'ext' else scope + ':'
        embed_file = add(prefix + 'embed:file', 'PBXBuildFile', fileRef=extension_products[scope],
                         settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']})
        embed_phases.append(add(prefix + 'embed', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647,
                                dstPath='', dstSubfolderSpec=13, files=[embed_file],
                                name='Embed App Extensions' if scope == 'ext' else 'Embed Nine-Key Extension',
                                runOnlyForDeploymentPostprocessing=0))
        proxy = add(prefix + 'proxy', 'PBXContainerItemProxy', containerPortal=uid('project'), proxyType=1,
                    remoteGlobalIDString=extension_ids[scope], remoteInfo=spec.name)
        dependencies.append(add(prefix + 'dependency', 'PBXTargetDependency',
                                target=extension_ids[scope], targetProxy=proxy))

    common = {
        'ALWAYS_SEARCH_USER_PATHS': 'NO', 'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
        'CLANG_CXX_LANGUAGE_STANDARD': 'c++17', 'CLANG_CXX_LIBRARY': 'libc++',
        'GCC_C_LANGUAGE_STANDARD': 'gnu17', 'GCC_WARN_ABOUT_RETURN_TYPE': 'YES_ERROR',
        'IPHONEOS_DEPLOYMENT_TARGET': '26.0', 'SDKROOT': 'iphoneos', 'SWIFT_VERSION': '6.0',
        'TARGETED_DEVICE_FAMILY': '1', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'YES', 'COMPILATION_CACHE_ENABLE_CACHING': 'NO',
        'SWIFT_EMIT_LOC_STRINGS': 'NO', 'CODE_SIGN_STYLE': 'Automatic',
        'CURRENT_PROJECT_VERSION': BUILD_VERSION, 'MARKETING_VERSION': MARKETING_VERSION,
        'CODE_SIGN_ENTITLEMENTS': 'Config/Translation.entitlements',
    }
    app_settings = {
        'PRODUCT_BUNDLE_IDENTIFIER': APP_BUNDLE_IDENTIFIER, 'PRODUCT_NAME': '$(TARGET_NAME)',
        'INFOPLIST_FILE': 'Config/App-Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'],
        'SUPPORTS_MACCATALYST': 'NO',
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
    }

    def configs(scope, extra, target_name=None):
        identifiers = []
        for mode in ('Debug', 'Release'):
            settings = dict(extra)
            if target_name:
                key = (target_name, mode)
                if key in modules:
                    settings['PRODUCT_MODULE_NAME'] = modules[key]
            if scope == 'project':
                settings.update({
                    'DEBUG_INFORMATION_FORMAT': 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym',
                    'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode == 'Debug' else '-O',
                    'GCC_OPTIMIZATION_LEVEL': '0' if mode == 'Debug' else 's',
                    'ENABLE_TESTABILITY': 'YES' if mode == 'Debug' else 'NO',
                })
                if mode == 'Debug':
                    settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = ['DEBUG', '$(inherited)']
                    settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['DEBUG=1', '$(inherited)']
            identifiers.append(add(scope + ':config:' + mode, 'XCBuildConfiguration',
                                   buildSettings=settings, name=mode,
                                   **({'baseConfigurationReference': files['Config/Signing.xcconfig']}
                                      if scope == 'project' else {})))
        return add(scope + ':configs', 'XCConfigurationList', buildConfigurations=identifiers,
                   defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

    app_configs = configs('app', app_settings, APP_TARGET_NAME)
    extension_configs = {}
    for spec in KEYBOARDS:
        settings = {
            'PRODUCT_BUNDLE_IDENTIFIER': spec.bundle_identifier, 'PRODUCT_NAME': '$(TARGET_NAME)',
            'INFOPLIST_FILE': 'Config/' + spec.info_file, 'GENERATE_INFOPLIST_FILE': 'NO',
            'SKIP_INSTALL': 'YES', 'APPLICATION_EXTENSION_API_ONLY': 'YES',
            'SWIFT_OBJC_BRIDGING_HEADER': bridge_header,
            'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'],
        }
        extension_configs[spec.scope] = configs(spec.scope, settings, spec.name)
    project_configs = configs('project', common)
    app_target = add('target:app', 'PBXNativeTarget', object_id=app_target_id,
                     buildConfigurationList=app_configs,
                     buildPhases=[app_sources, app_frameworks, app_resources] + embed_phases,
                     buildRules=[], dependencies=dependencies, name=APP_TARGET_NAME,
                     productName=APP_TARGET_NAME, productReference=app_product,
                     productType='com.apple.product-type.application')
    targets = [app_target]
    for spec in KEYBOARDS:
        targets.append(add('target:' + spec.scope, 'PBXNativeTarget', object_id=extension_ids[spec.scope],
                           buildConfigurationList=extension_configs[spec.scope],
                           buildPhases=extension_phases[spec.scope], buildRules=[], dependencies=[],
                           name=spec.name, productName=spec.name,
                           productReference=extension_products[spec.scope],
                           productType='com.apple.product-type.app-extension'))
    project_id = add('project', 'PBXProject', attributes={
        'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '2660',
        'TargetAttributes': {identifier: {'CreatedOnToolsVersion': '26.6',
                                        'SystemCapabilities': {'com.apple.Keychain': {'enabled': 1}}}
                             for identifier in targets},
    }, buildConfigurationList=project_configs, compatibilityVersion='Xcode 14.0',
        developmentRegion='zh_CN', hasScannedForEncodings=0, knownRegions=['zh_CN', 'en', 'Base'],
        mainGroup=main_group, productRefGroup=products, projectDirPath='', projectRoot='', targets=targets)

    # Construct everything before writing; failed parsing above never replaces signing data.
    project.mkdir(exist_ok=True)
    (root / 'Config').mkdir(exist_ok=True)
    # Preserve this machine's selected team outside version control.
    local_signing = root / 'Config/Local.xcconfig'
    selected_teams = set(teams.values())
    if not local_signing.exists() and len(selected_teams) == 1:
        local_signing.write_text('// Local developer signing; do not commit.\nDEVELOPMENT_TEAM = ' +
                                 next(iter(selected_teams)) + '\n')
    for filename, info in info_files.items():
        with (root / 'Config' / filename).open('wb') as stream:
            plistlib.dump(info, stream, sort_keys=False)
    contents = {'archiveVersion': 1, 'classes': {}, 'objectVersion': 56,
                'objects': objects, 'rootObject': project_id}
    project_file.write_text('// !$*UTF8*$!\n' + dump(contents) + '\n')
    write_scheme(project, app_target)
    write_workspace(project)
    print(f'Generated {project}: one app, two keyboard extensions, build {BUILD_VERSION}')


def write_scheme(project, app_target):
    scheme_dir = project / 'xcshareddata/xcschemes'
    scheme_dir.mkdir(parents=True, exist_ok=True)
    scheme = ET.Element('Scheme', LastUpgradeVersion='2660', version='1.3')

    def build_ref(parent):
        ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary',
                      BlueprintIdentifier=app_target, BuildableName=APP_TARGET_NAME + '.app',
                      BlueprintName=APP_TARGET_NAME, ReferencedContainer='container:EnglishHintKeyboard.xcodeproj')

    build = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
    entries = ET.SubElement(build, 'BuildActionEntries')
    build_ref(ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES',
                            buildForProfiling='YES', buildForArchiving='YES', buildForAnalyzing='YES'))
    ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug',
                  selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                  selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
    launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug',
                           selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                           selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0',
                           useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO',
                           debugDocumentVersioning='YES', debugServiceExtension='internal', allowLocationSimulation='YES')
    build_ref(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'))
    profile = ET.SubElement(scheme, 'ProfileAction', buildConfiguration='Release', shouldUseLaunchSchemeArgsEnv='YES',
                            savedToolIdentifier='', useCustomWorkingDirectory='NO', debugDocumentVersioning='YES')
    build_ref(ET.SubElement(profile, 'BuildableProductRunnable', runnableDebuggingMode='0'))
    ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug')
    ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
    ET.indent(scheme)
    ET.ElementTree(scheme).write(scheme_dir / 'EnglishHintKeyboard.xcscheme', encoding='UTF-8', xml_declaration=True)


def write_workspace(project):
    workspace = project / 'project.xcworkspace'
    (workspace / 'xcshareddata').mkdir(parents=True, exist_ok=True)
    (workspace / 'contents.xcworkspacedata').write_text(
        '<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')
    with (workspace / 'xcshareddata/WorkspaceSettings.xcsettings').open('wb') as stream:
        plistlib.dump({'DerivedDataLocationStyle': 'WorkspaceRelativePath',
                      'DerivedDataCustomLocation': '../build/XcodeGUI',
                      'BuildLocationStyle': 'UseAppPreferences'}, stream)


if __name__ == '__main__':
    generate(Path(__file__).resolve().parent.parent)
