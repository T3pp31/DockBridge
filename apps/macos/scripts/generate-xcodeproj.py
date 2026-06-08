#!/usr/bin/env python3
"""Generate a minimal DockBridge.xcodeproj from Swift sources."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = ROOT / "DockBridge.xcodeproj"
SRC_ROOT = ROOT / "DockBridge"


def uid(seed: str) -> str:
    return hashlib.md5(f"dockbridge-{seed}".encode()).hexdigest()[:24].upper()


SWIFT_FILES = sorted(
    p.relative_to(ROOT).as_posix()
    for p in SRC_ROOT.rglob("*.swift")
)

RESOURCE_BUILD_FILES = [
    "DockBridge/Resources/Assets.xcassets",
]

FILE_REFERENCES_EXTRA = [
    "DockBridge/Resources/Info.plist",
    "DockBridge/Resources/DockBridge.entitlements",
]

# Fixed IDs
PROJECT_ID = uid("project")
TARGET_ID = uid("target")
SOURCES_PHASE = uid("sources-phase")
RESOURCES_PHASE = uid("resources-phase")
FRAMEWORKS_PHASE = uid("frameworks-phase")
PRODUCT_REF = uid("product-ref")
CONFIG_LIST_PROJECT = uid("config-list-project")
CONFIG_LIST_TARGET = uid("config-list-target")
DEBUG_CONFIG = uid("debug-config")
RELEASE_CONFIG = uid("release-config")
DEBUG_TARGET_CONFIG = uid("debug-target-config")
RELEASE_TARGET_CONFIG = uid("release-target-config")
BUILD_SCRIPT = uid("build-script")

file_refs: dict[str, str] = {}
build_files: dict[str, str] = {}

ALL_REF_PATHS = SWIFT_FILES + RESOURCE_BUILD_FILES + FILE_REFERENCES_EXTRA

for path in ALL_REF_PATHS:
    file_refs[path] = uid(f"ref-{path}")
    if path.endswith(".swift"):
        build_files[path] = uid(f"build-{path}")

groups: dict[str, list[str]] = {}
all_group_paths: set[str] = set()
for path in ALL_REF_PATHS:
    parts = Path(path).parts
    for depth in range(1, len(parts)):
        all_group_paths.add("/".join(parts[:depth]))
    parent = "/".join(parts[:-1])
    groups.setdefault(parent, []).append(path)

lines: list[str] = []
lines.append("// !$*UTF8*$!")
lines.append("{")
lines.append("\tarchiveVersion = 1;")
lines.append("\tclasses = {};")
lines.append("\tobjectVersion = 56;")
lines.append("\tobjects = {")

# PBXBuildFile
lines.append("\n/* Begin PBXBuildFile section */")
for path, bf_id in build_files.items():
    lines.append(f"\t\t{bf_id} /* {Path(path).name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {Path(path).name} */; }};")
for path in RESOURCE_BUILD_FILES:
    lines.append(
        f"\t\t{uid(f'build-{path}')} /* {Path(path).name} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {Path(path).name} */; }};"
    )
lines.append("/* End PBXBuildFile section */")

# PBXFileReference
lines.append("\n/* Begin PBXFileReference section */")
lines.append(f"\t\t{PRODUCT_REF} /* DockBridge.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = DockBridge.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
for path in ALL_REF_PATHS:
    file_type = "sourcecode.swift" if path.endswith(".swift") else (
        "folder.assetcatalog" if path.endswith(".xcassets") else (
            "text.plist.entitlements" if path.endswith(".entitlements") else "text.plist.xml"
        )
    )
    lines.append(
        f"\t\t{file_refs[path]} /* {Path(path).name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = {Path(path).name}; sourceTree = \"<group>\"; }};"
    )
lines.append("/* End PBXFileReference section */")

# PBXFrameworksBuildPhase
lines.append("\n/* Begin PBXFrameworksBuildPhase section */")
lines.append(f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{")
lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXFrameworksBuildPhase section */")

# PBXGroup
lines.append("\n/* Begin PBXGroup section */")
products_group = uid("group-products")
lines.append(f"\t\t{products_group} /* Products */ = {{")
lines.append("\t\t\tisa = PBXGroup;")
lines.append("\t\t\tchildren = (")
lines.append(f"\t\t\t\t{PRODUCT_REF} /* DockBridge.app */,")
lines.append("\t\t\t);")
lines.append("\t\t\tname = Products;")
lines.append("\t\t\tsourceTree = \"<group>\";")
lines.append("\t\t};")

def emit_group(name: str, group_id: str, children_paths: list[str], child_groups: list[tuple[str, str]]):
    lines.append(f"\t\t{group_id} /* {name} */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for gid, gname in child_groups:
        lines.append(f"\t\t\t\t{gid} /* {gname} */,")
    for path in sorted(children_paths):
        lines.append(f"\t\t\t\t{file_refs[path]} /* {Path(path).name} */,")
    lines.append("\t\t\t);")
    if name != "Products":
        lines.append(f"\t\t\tpath = {name};")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

main_group = uid("group-main")
dockbridge_group = uid("group-dockbridge")

# Build nested groups (include intermediate folders such as DockBridge/Views).
group_ids: dict[str, str] = {}
for key in sorted(all_group_paths):
    group_ids[key] = dockbridge_group if key == "DockBridge" else uid(f"group-{key}")

for key in sorted(group_ids.keys(), key=lambda k: k.count("/"), reverse=True):
    child_groups = [
        (group_ids[sub], Path(sub).name)
        for sub in sorted(group_ids)
        if sub.startswith(key + "/") and sub.count("/") == key.count("/") + 1
    ]
    direct_files = groups.get(key, [])
    emit_group(Path(key).name, group_ids[key], direct_files, child_groups)

lines.append(f"\t\t{main_group} = {{")
lines.append("\t\t\tisa = PBXGroup;")
lines.append("\t\t\tchildren = (")
lines.append(f"\t\t\t\t{dockbridge_group} /* DockBridge */,")
lines.append(f"\t\t\t\t{products_group} /* Products */,")
lines.append("\t\t\t);")
lines.append("\t\t\tsourceTree = \"<group>\";")
lines.append("\t\t};")
lines.append("/* End PBXGroup section */")

# PBXNativeTarget
lines.append("\n/* Begin PBXNativeTarget section */")
lines.append(f"\t\t{TARGET_ID} /* DockBridge */ = {{")
lines.append("\t\t\tisa = PBXNativeTarget;")
lines.append("\t\t\tbuildConfigurationList = {CONFIG_LIST_TARGET} /* Build configuration list for PBXNativeTarget \"DockBridge\" */;".format(CONFIG_LIST_TARGET=CONFIG_LIST_TARGET))
lines.append("\t\t\tbuildPhases = (")
lines.append(f"\t\t\t\t{BUILD_SCRIPT} /* Generate UniFFI Bindings */,")
lines.append(f"\t\t\t\t{SOURCES_PHASE} /* Sources */,")
lines.append(f"\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,")
lines.append(f"\t\t\t\t{RESOURCES_PHASE} /* Resources */,")
lines.append("\t\t\t);")
lines.append("\t\t\tbuildRules = (")
lines.append("\t\t\t);")
lines.append("\t\t\tdependencies = (")
lines.append("\t\t\t);")
lines.append("\t\t\tname = DockBridge;")
lines.append(f"\t\t\tproductName = DockBridge;")
lines.append(f"\t\t\tproductReference = {PRODUCT_REF} /* DockBridge.app */;")
lines.append("\t\t\tproductType = \"com.apple.product-type.application\";")
lines.append("\t\t};")
lines.append("/* End PBXNativeTarget section */")

# PBXProject
lines.append("\n/* Begin PBXProject section */")
lines.append(f"\t\t{PROJECT_ID} /* Project object */ = {{")
lines.append("\t\t\tisa = PBXProject;")
lines.append("\t\t\tattributes = {")
lines.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
lines.append("\t\t\t\tLastSwiftUpdateCheck = 1600;")
lines.append("\t\t\t\tLastUpgradeCheck = 1600;")
lines.append("\t\t\t};")
lines.append(f"\t\t\tbuildConfigurationList = {CONFIG_LIST_PROJECT} /* Build configuration list for PBXProject \"DockBridge\" */;")
lines.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
lines.append("\t\t\tdevelopmentRegion = en;")
lines.append("\t\t\thasScannedForEncodings = 0;")
lines.append("\t\t\tknownRegions = (")
lines.append("\t\t\t\ten,")
lines.append("\t\t\t\tBase,")
lines.append("\t\t\t);")
lines.append(f"\t\t\tmainGroup = {main_group};")
lines.append(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
lines.append("\t\t\tprojectDirPath = \"\";")
lines.append("\t\t\tprojectRoot = \"\";")
lines.append("\t\t\ttargets = (")
lines.append(f"\t\t\t\t{TARGET_ID} /* DockBridge */,")
lines.append("\t\t\t);")
lines.append("\t\t};")
lines.append("/* End PBXProject section */")

# PBXResourcesBuildPhase
lines.append("\n/* Begin PBXResourcesBuildPhase section */")
lines.append(f"\t\t{RESOURCES_PHASE} /* Resources */ = {{")
lines.append("\t\t\tisa = PBXResourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
for path in RESOURCE_BUILD_FILES:
    lines.append(f"\t\t\t\t{uid(f'build-{path}')} /* {Path(path).name} in Resources */,")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXResourcesBuildPhase section */")

# PBXShellScriptBuildPhase
lines.append("\n/* Begin PBXShellScriptBuildPhase section */")
lines.append(f"\t\t{BUILD_SCRIPT} /* Generate UniFFI Bindings */ = {{")
lines.append("\t\t\tisa = PBXShellScriptBuildPhase;")
lines.append("\t\t\talwaysOutOfDate = 1;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
lines.append("\t\t\t);")
lines.append("\t\t\tinputFileListPaths = (")
lines.append("\t\t\t);")
lines.append("\t\t\tinputPaths = (")
lines.append("\t\t\t);")
lines.append('\t\t\tname = "Generate UniFFI Bindings";')
lines.append("\t\t\toutputFileListPaths = (")
lines.append("\t\t\t);")
lines.append("\t\t\toutputPaths = (")
lines.append("\t\t\t);")
lines.append(
    "\t\t\tshellScript = \"set -euo pipefail\\nROOT=\\\"${SRCROOT}/../..\\\"\\nif [[ -x \\\"${ROOT}/scripts/generate-uniffi.sh\\\" ]]; then\\n  \\\"${ROOT}/scripts/generate-uniffi.sh\\\" || true\\nfi\\n\";"
)
lines.append("\t\t};")
lines.append("/* End PBXShellScriptBuildPhase section */")

# PBXSourcesBuildPhase
lines.append("\n/* Begin PBXSourcesBuildPhase section */")
lines.append(f"\t\t{SOURCES_PHASE} /* Sources */ = {{")
lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
for path in SWIFT_FILES:
    lines.append(f"\t\t\t\t{build_files[path]} /* {Path(path).name} in Sources */,")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXSourcesBuildPhase section */")

# XCBuildConfiguration
common_debug = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": (
        "DEBUG=1",
        "$(inherited)",
    ),
    "MACOSX_DEPLOYMENT_TARGET": "15.0",
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SDKROOT": "macosx",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    "SWIFT_VERSION": "5.10",
}
common_release = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "15.0",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SDKROOT": "macosx",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_VERSION": "5.10",
}
target_settings = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_ENTITLEMENTS": "DockBridge/Resources/DockBridge.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "COMBINE_HIDPI_IMAGES": "YES",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "GENERATE_INFOPLIST_FILE": "NO",
    "HEADER_SEARCH_PATHS": "$(PROJECT_DIR)/DockBridge/Generated/Headers",
    "SWIFT_INCLUDE_PATHS": "$(PROJECT_DIR)/DockBridge/Generated/Headers",
    "INFOPLIST_FILE": "DockBridge/Resources/Info.plist",
    "LIBRARY_SEARCH_PATHS": (
        "$(inherited)",
        "$(PROJECT_DIR)/../../target/debug",
        "$(PROJECT_DIR)/../../target/release",
        "$(PROJECT_DIR)/../../target/aarch64-apple-darwin/debug",
        "$(PROJECT_DIR)/../../target/aarch64-apple-darwin/release",
        "$(PROJECT_DIR)/../../target/x86_64-apple-darwin/debug",
        "$(PROJECT_DIR)/../../target/x86_64-apple-darwin/release",
    ),
    "MARKETING_VERSION": "0.1.0",
    "OTHER_LDFLAGS": (
        "$(inherited)",
        "-ldockbridge_uniffi",
        "-lc++",
        "-framework",
        "Security",
    ),
    "PRODUCT_BUNDLE_IDENTIFIER": "com.dockbridge.app",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_STRICT_CONCURRENCY": "complete",
}


def fmt_settings(settings: dict) -> str:
    out = []
    for key, value in settings.items():
        if isinstance(value, tuple):
            out.append(f"\t\t\t\t{key} = (")
            for item in value:
                out.append(f'\t\t\t\t\t"{item}",')
            out.append("\t\t\t\t);")
        else:
            out.append(f'\t\t\t\t{key} = "{value}";')
    return "\n".join(out)


lines.append("\n/* Begin XCBuildConfiguration section */")
for cfg_id, name, base, extra in [
    (DEBUG_CONFIG, "Debug", common_debug, {}),
    (RELEASE_CONFIG, "Release", common_release, {}),
    (DEBUG_TARGET_CONFIG, "Debug", common_debug, target_settings),
    (RELEASE_TARGET_CONFIG, "Release", common_release, target_settings),
]:
    merged = {**base, **extra}
    lines.append(f"\t\t{cfg_id} /* {name} */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append(fmt_settings(merged))
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = {};".format(name))
    lines.append("\t\t};")

lines.append("/* End XCBuildConfiguration section */")

# XCConfigurationList
lines.append("\n/* Begin XCConfigurationList section */")
for list_id, name, cfgs in [
    (CONFIG_LIST_PROJECT, "Build configuration list for PBXProject \"DockBridge\"", [(DEBUG_CONFIG, "Debug"), (RELEASE_CONFIG, "Release")]),
    (CONFIG_LIST_TARGET, "Build configuration list for PBXNativeTarget \"DockBridge\"", [(DEBUG_TARGET_CONFIG, "Debug"), (RELEASE_TARGET_CONFIG, "Release")]),
]:
    lines.append(f"\t\t{list_id} /* {name} */ = {{")
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    for cfg_id, cfg_name in cfgs:
        lines.append(f"\t\t\t\t{cfg_id} /* {cfg_name} */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
lines.append("/* End XCConfigurationList section */")

lines.append("\t};")
lines.append(f"\trootObject = {PROJECT_ID} /* Project object */;")
lines.append("}")

PROJECT_DIR.mkdir(parents=True, exist_ok=True)
(PROJECT_DIR / "project.pbxproj").write_text("\n".join(lines) + "\n", encoding="utf-8")

scheme_dir = PROJECT_DIR / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
scheme_dir.joinpath("DockBridge.xcscheme").write_text(
    f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TARGET_ID}"
               BuildableName = "DockBridge.app"
               BlueprintName = "DockBridge"
               ReferencedContainer = "container:DockBridge.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET_ID}"
            BuildableName = "DockBridge.app"
            BlueprintName = "DockBridge"
            ReferencedContainer = "container:DockBridge.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
""",
    encoding="utf-8",
)

print(f"Wrote {PROJECT_DIR / 'project.pbxproj'}")
print(f"Swift sources: {len(SWIFT_FILES)}")
