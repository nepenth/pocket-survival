#!/usr/bin/env python3
"""Generates PocketMirror.xcodeproj/project.pbxproj.

The project is written by this script (there is no local Xcode that can target iOS 14), so add new
source files to SWIFT_FILES (or HEADERS) below and re-run:  python3 apps/PocketMirror/tools/gen_pbxproj.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "PocketMirror.xcodeproj", "project.pbxproj")

MARKETING_VERSION = "0.5.0"
BUNDLE_ID = "net.pocketsurvival.mirror"

# (file name, subgroup under PocketMirror/ or None)
SWIFT_FILES = [
    ("PocketMirrorApp.swift", None),
    ("ContentView.swift", None),
    ("MirrorModel.swift", None),
    ("MirrorWebView.swift", None),
    ("HTTPCore.swift", "Server"),
    ("MirrorServer.swift", "Server"),
    ("KiwixServer.mm", "Kiwix"),          # Objective-C++ bridge to libkiwix
]
# Headers: listed in the project but not compiled on their own.
HEADERS = [
    ("KiwixServer.h", "Kiwix"),
    ("PocketMirror-Bridging-Header.h", None),
]
# libkiwix and its dependencies, built for iOS 14 by ci/build-libkiwix-ios14.sh (not committed).
KIWIX_XCFRAMEWORK = "build/kiwix/CoreKiwix.xcframework"


def filetype(name):
    return {"swift": "sourcecode.swift", "mm": "sourcecode.cpp.objcpp", "h": "sourcecode.c.h"}[name.rsplit(".", 1)[1]]

_ids = {}


def oid(name):
    """Stable 24-hex-digit object id per logical name."""
    if name not in _ids:
        _ids[name] = "B10C0000000000000000%04X" % (len(_ids) + 1)
    return _ids[name]


def target_settings(cfg):
    opt = ('SWIFT_OPTIMIZATION_LEVEL = "-Onone";' if cfg == "Debug"
           else "SWIFT_COMPILATION_MODE = wholemodule;")
    return f"""				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++17";
				CLANG_CXX_LIBRARY = "libc++";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = PocketMirror/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "Pocket Mirror";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				IPHONEOS_DEPLOYMENT_TARGET = 14.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = {MARKETING_VERSION};
				OTHER_LDFLAGS = (
					"$(inherited)",
					"-lc++",
					"-liconv",
					"-framework",
					Security,
					"-framework",
					SystemConfiguration,
					"-framework",
					CFNetwork,
				);
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = PocketMirror;
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_OBJC_BRIDGING_HEADER = "PocketMirror/PocketMirror-Bridging-Header.h";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 1;
				{opt}"""


def project_settings(cfg):
    common = """				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				IPHONEOS_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = iphoneos;"""
    if cfg == "Debug":
        return common + """
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;"""
    return common + """
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				VALIDATE_PRODUCT = YES;"""


def main():
    nl = "\n"
    buildfiles = [f"\t\t{oid('bf_' + f)} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {oid('fr_' + f)} /* {f} */; }};"
                  for f, _ in SWIFT_FILES]
    buildfiles += [
        f"\t\t{oid('bf_kiwix')} /* CoreKiwix.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {oid('fr_kiwix')} /* CoreKiwix.xcframework */; }};",
        f"\t\t{oid('bf_assets')} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {oid('fr_assets')} /* Assets.xcassets */; }};",
        f"\t\t{oid('bf_demo')} /* Web in Resources */ = {{isa = PBXBuildFile; fileRef = {oid('fr_demo')} /* Web */; }};",
    ]
    filerefs = [f"\t\t{oid('fr_' + f)} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {filetype(f)}; path = {f}; sourceTree = \"<group>\"; }};"
                for f, _ in SWIFT_FILES + HEADERS]
    filerefs.append(f"\t\t{oid('fr_kiwix')} /* CoreKiwix.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = CoreKiwix.xcframework; path = {KIWIX_XCFRAMEWORK}; sourceTree = SOURCE_ROOT; }};")
    filerefs += [
        f"\t\t{oid('fr_assets')} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};",
        f"\t\t{oid('fr_demo')} /* Web */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = Web; sourceTree = \"<group>\"; }};",
        f"\t\t{oid('fr_plist')} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};",
        f"\t\t{oid('fr_app')} /* PocketMirror.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PocketMirror.app; sourceTree = BUILT_PRODUCTS_DIR; }};",
    ]
    all_files = SWIFT_FILES + HEADERS
    subgroups = sorted({g for _, g in all_files if g})
    top_children = nl.join(f"\t\t\t\t{oid('fr_' + f)} /* {f} */," for f, g in all_files if g is None)
    top_children += nl + nl.join(f"\t\t\t\t{oid('grp_' + g)} /* {g} */," for g in subgroups)
    subgroup_defs = ""
    for g in subgroups:
        kids = nl.join(f"\t\t\t\t{oid('fr_' + f)} /* {f} */," for f, gg in all_files if gg == g)
        subgroup_defs += f"""		{oid('grp_' + g)} /* {g} */ = {{
			isa = PBXGroup;
			children = (
{kids}
			);
			path = {g};
			sourceTree = "<group>";
		}};
"""
    sources = nl.join(f"\t\t\t\t{oid('bf_' + f)} /* {f} in Sources */," for f, _ in SWIFT_FILES)

    pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{nl.join(buildfiles)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{nl.join(filerefs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{oid('phase_fw')} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{oid('bf_kiwix')} /* CoreKiwix.xcframework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{oid('grp_root')} = {{
			isa = PBXGroup;
			children = (
				{oid('grp_src')} /* PocketMirror */,
				{oid('fr_kiwix')} /* CoreKiwix.xcframework */,
				{oid('grp_products')} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{oid('grp_src')} /* PocketMirror */ = {{
			isa = PBXGroup;
			children = (
{top_children}
				{oid('fr_assets')} /* Assets.xcassets */,
				{oid('fr_demo')} /* Web */,
				{oid('fr_plist')} /* Info.plist */,
			);
			path = PocketMirror;
			sourceTree = "<group>";
		}};
{subgroup_defs}		{oid('grp_products')} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{oid('fr_app')} /* PocketMirror.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{oid('target')} /* PocketMirror */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {oid('cfglist_target')} /* Build configuration list for PBXNativeTarget "PocketMirror" */;
			buildPhases = (
				{oid('phase_src')} /* Sources */,
				{oid('phase_fw')} /* Frameworks */,
				{oid('phase_res')} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = PocketMirror;
			productName = PocketMirror;
			productReference = {oid('fr_app')} /* PocketMirror.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{oid('project')} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1640;
				LastUpgradeCheck = 1640;
			}};
			buildConfigurationList = {oid('cfglist_project')} /* Build configuration list for PBXProject "PocketMirror" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {oid('grp_root')};
			productRefGroup = {oid('grp_products')} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{oid('target')} /* PocketMirror */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{oid('phase_res')} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{oid('bf_assets')} /* Assets.xcassets in Resources */,
				{oid('bf_demo')} /* Web in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{oid('phase_src')} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{oid('cfg_proj_debug')} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{project_settings('Debug')}
			}};
			name = Debug;
		}};
		{oid('cfg_proj_release')} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{project_settings('Release')}
			}};
			name = Release;
		}};
		{oid('cfg_target_debug')} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_settings('Debug')}
			}};
			name = Debug;
		}};
		{oid('cfg_target_release')} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_settings('Release')}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{oid('cfglist_project')} /* Build configuration list for PBXProject "PocketMirror" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{oid('cfg_proj_debug')} /* Debug */,
				{oid('cfg_proj_release')} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{oid('cfglist_target')} /* Build configuration list for PBXNativeTarget "PocketMirror" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{oid('cfg_target_debug')} /* Debug */,
				{oid('cfg_target_release')} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {oid('project')} /* Project object */;
}}
"""
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as fh:
        fh.write(pbx)
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
