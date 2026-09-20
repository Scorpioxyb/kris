#!/usr/bin/env python3
"""Generate the dependency-free Xcode project used by Kris V1."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "KrisCoach.xcodeproj"
SCHEME_DIRECTORY = PROJECT / "xcshareddata" / "xcschemes"


class IDs:
    next = 1

    @classmethod
    def make(cls) -> str:
        value = f"A1{cls.next:022X}"
        cls.next += 1
        return value


def q(value: str) -> str:
    return f'"{value}"' if any(ch in value for ch in " .-/") or value.startswith("_") else value


def array(values: list[str]) -> str:
    return "()" if not values else f"({', '.join(values)}, )"


def write_main_scheme(targets: dict[str, str]) -> None:
    """Keep the shared test action available after project regeneration."""
    SCHEME_DIRECTORY.mkdir(parents=True, exist_ok=True)
    app_target = targets["ios"]
    preview_target = targets["preview"]
    unit_test_target = targets["tests"]
    ui_test_target = targets["uitests"]
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "NO"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "KrisCoach.app"
               BlueprintName = "KrisCoach"
               ReferencedContainer = "container:KrisCoach.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{preview_target}"
               BuildableName = "KrisCoach Preview.app"
               BlueprintName = "KrisCoach Preview"
               ReferencedContainer = "container:KrisCoach.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{unit_test_target}"
               BuildableName = "KrisCoachTests.xctest"
               BlueprintName = "KrisCoachTests"
               ReferencedContainer = "container:KrisCoach.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ui_test_target}"
               BuildableName = "KrisCoachUITests.xctest"
               BlueprintName = "KrisCoachUITests"
               ReferencedContainer = "container:KrisCoach.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
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
            BlueprintIdentifier = "{app_target}"
            BuildableName = "KrisCoach.app"
            BlueprintName = "KrisCoach"
            ReferencedContainer = "container:KrisCoach.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "KrisCoach.app"
            BlueprintName = "KrisCoach"
            ReferencedContainer = "container:KrisCoach.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    (SCHEME_DIRECTORY / "KrisCoach.xcscheme").write_text(scheme, encoding="utf-8")


def main() -> None:
    PROJECT.mkdir(parents=True, exist_ok=True)
    files = {
        "Shared": [
            "Contracts.swift", "AIContracts.swift", "AIDecisionContextBuilder.swift",
            "ReadinessEngine.swift", "HealthReducers.swift",
            "TrainingIntelligence.swift", "PersistenceModels.swift",
            "WatchExecutionPersistence.swift",
        ],
        "iPhone": ["KrisCoachApp.swift", "AppModel.swift", "AIService.swift", "AIWireContracts.swift", "AIViews.swift", "KeychainStore.swift", "CompanionClient.swift", "BonjourBrowser.swift", "HealthKitService.swift", "PhoneWatchConnectivity.swift", "MirroredWorkoutCoordinator.swift", "WorkoutLiveActivityController.swift", "DesignSystem.swift", "OnboardingView.swift", "Views.swift", "QRCodeScannerView.swift", "KrisCoach.entitlements"],
        "Watch": ["KrisCoachWatchApp.swift", "WatchAppModel.swift", "WatchEventQueue.swift", "WatchExecutionStore.swift", "WorkoutManager.swift", "WatchViews.swift", "KrisCoachWatch.entitlements", "Info.plist"],
        "LiveActivity": ["WorkoutActivityAttributes.swift", "KrisLiveActivity.swift", "Info.plist"],
        "Tests": [
            "ReadinessEngineTests.swift", "AIDecisionPipelineTests.swift",
            "AIDecisionPipelineIntegrationTests.swift",
        ],
        "UITests": ["KrisCoachUITests.swift"],
        "Resources": ["PrivacyInfo.xcprivacy", "Assets.xcassets"],
    }
    external = {
        "readiness.v1.json": "../shared/rules/readiness.v1.json",
        "readiness_golden.v1.json": "../shared/fixtures/readiness_golden.v1.json",
        "TrainingPlan.sample.json": "../shared/examples/TrainingPlan.sample.json",
    }
    refs = {f"{group}/{name}": IDs.make() for group, names in files.items() for name in names}
    refs.update({name: IDs.make() for name in external})
    groups = {name: IDs.make() for name in [*files, "External Resources", "Products"]}
    main_group = IDs.make()
    project_id = IDs.make()
    products = {name: IDs.make() for name in ["KrisCoach.app", "KrisCoach Preview.app", "Kris.app", "KrisLiveActivity.appex", "KrisCoachTests.xctest", "KrisCoachUITests.xctest"]}

    ios_sources = [f"Shared/{name}" for name in files["Shared"]] + [f"iPhone/{name}" for name in files["iPhone"] if name.endswith(".swift")] + ["LiveActivity/WorkoutActivityAttributes.swift"]
    watch_sources = [
        "Shared/Contracts.swift", "Shared/WatchExecutionPersistence.swift",
    ] + [f"Watch/{name}" for name in files["Watch"] if name.endswith(".swift")]
    test_sources = [
        "Tests/ReadinessEngineTests.swift", "Tests/AIDecisionPipelineTests.swift",
        "Tests/AIDecisionPipelineIntegrationTests.swift",
    ]
    ui_sources = ["UITests/KrisCoachUITests.swift"]
    live_activity_sources = ["LiveActivity/WorkoutActivityAttributes.swift", "LiveActivity/KrisLiveActivity.swift"]
    source_lists = {"ios": ios_sources, "preview": ios_sources, "watch": watch_sources, "live_activity": live_activity_sources, "tests": test_sources, "uitests": ui_sources}
    build_files = {(target, path): IDs.make() for target, paths in source_lists.items() for path in paths}
    ios_resources = ["Resources/PrivacyInfo.xcprivacy", "Resources/Assets.xcassets", "readiness.v1.json", "readiness_golden.v1.json"]
    preview_resources = [*ios_resources, "TrainingPlan.sample.json"]
    watch_app_resources = ["Resources/Assets.xcassets"]
    resource_build = {path: IDs.make() for path in ios_resources}
    preview_resource_build = {path: IDs.make() for path in preview_resources}
    watch_resource_build = {path: IDs.make() for path in watch_app_resources}
    test_resource_build = {name: IDs.make() for name in ["readiness.v1.json", "readiness_golden.v1.json"]}
    phases = {key: IDs.make() for key in ["ios_sources", "ios_frameworks", "ios_resources", "ios_embed_watch", "ios_embed_extensions", "preview_sources", "preview_frameworks", "preview_resources", "watch_app_resources", "watch_sources", "watch_frameworks", "live_activity_sources", "live_activity_frameworks", "live_activity_resources", "test_sources", "test_frameworks", "test_resources", "ui_sources", "ui_frameworks", "ui_resources"]}
    configs = {key: (IDs.make(), IDs.make(), IDs.make()) for key in ["project", "ios", "preview", "watch", "live_activity", "tests", "uitests"]}
    targets = {name: IDs.make() for name in ["ios", "preview", "watch", "live_activity", "tests", "uitests"]}
    watch_proxy, watch_dependency, live_activity_proxy, live_activity_dependency, test_proxy, test_dependency, ui_proxy, ui_dependency = [IDs.make() for _ in range(8)]
    embed_watch_build = IDs.make()
    embed_live_activity_build = IDs.make()

    lines: list[str] = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {};", "\tobjectVersion = 56;", "\tobjects = {", ""]
    lines.append("/* Begin PBXBuildFile section */")
    for (target, path), ident in build_files.items():
        lines.append(f"\t\t{ident} /* {Path(path).name} in Sources */ = {{isa = PBXBuildFile; fileRef = {refs[path]} /* {Path(path).name} */; }};")
    for path, ident in resource_build.items():
        key = path if path in refs else path
        lines.append(f"\t\t{ident} /* {Path(path).name} in Resources */ = {{isa = PBXBuildFile; fileRef = {refs[key]} /* {Path(path).name} */; }};")
    for path, ident in preview_resource_build.items():
        lines.append(f"\t\t{ident} /* {Path(path).name} in Resources */ = {{isa = PBXBuildFile; fileRef = {refs[path]} /* {Path(path).name} */; }};")
    for path, ident in watch_resource_build.items():
        lines.append(f"\t\t{ident} /* {Path(path).name} in Resources */ = {{isa = PBXBuildFile; fileRef = {refs[path]} /* {Path(path).name} */; }};")
    for path, ident in test_resource_build.items():
        lines.append(f"\t\t{ident} /* {path} in Resources */ = {{isa = PBXBuildFile; fileRef = {refs[path]} /* {path} */; }};")
    lines.append(f"\t\t{embed_watch_build} /* Kris.app in Embed Watch Content */ = {{isa = PBXBuildFile; fileRef = {products['Kris.app']} /* Kris.app */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")
    lines.append(f"\t\t{embed_live_activity_build} /* KrisLiveActivity.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {products['KrisLiveActivity.appex']} /* KrisLiveActivity.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")
    lines.append("/* End PBXBuildFile section */\n")

    lines.extend(["/* Begin PBXContainerItemProxy section */",
        f"\t\t{watch_proxy} = {{isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {targets['watch']}; remoteInfo = \"KrisCoach Watch\"; }};",
        f"\t\t{live_activity_proxy} = {{isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {targets['live_activity']}; remoteInfo = \"KrisLiveActivity\"; }};",
        f"\t\t{test_proxy} = {{isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {targets['preview']}; remoteInfo = \"KrisCoach Preview\"; }};",
        f"\t\t{ui_proxy} = {{isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {targets['preview']}; remoteInfo = \"KrisCoach Preview\"; }};",
        "/* End PBXContainerItemProxy section */\n"])
    lines.extend(["/* Begin PBXCopyFilesBuildPhase section */",
        f"\t\t{phases['ios_embed_watch']} /* Embed Watch Content */ = {{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\"; dstSubfolderSpec = 16; files = ({embed_watch_build}, ); name = \"Embed Watch Content\"; runOnlyForDeploymentPostprocessing = 0; }};",
        f"\t\t{phases['ios_embed_extensions']} /* Embed App Extensions */ = {{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = ({embed_live_activity_build}, ); name = \"Embed App Extensions\"; runOnlyForDeploymentPostprocessing = 0; }};",
        "/* End PBXCopyFilesBuildPhase section */\n"])

    lines.append("/* Begin PBXFileReference section */")
    for group, names in files.items():
        for name in names:
            kind = "sourcecode.swift" if name.endswith(".swift") else "folder.assetcatalog" if name.endswith(".xcassets") else "text.plist.xml"
            lines.append(f"\t\t{refs[f'{group}/{name}']} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(name)}; sourceTree = \"<group>\"; }};")
    for name, path in external.items():
        lines.append(f"\t\t{refs[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.json; name = {q(name)}; path = {q(path)}; sourceTree = SOURCE_ROOT; }};")
    for name, ident in products.items():
        filetype = "wrapper.application" if name.endswith(".app") else "wrapper.app-extension" if name.endswith(".appex") else "wrapper.cfbundle"
        lines.append(f"\t\t{ident} /* {name} */ = {{isa = PBXFileReference; explicitFileType = {filetype}; includeInIndex = 0; path = {q(name)}; sourceTree = BUILT_PRODUCTS_DIR; }};")
    lines.append("/* End PBXFileReference section */\n")

    lines.append("/* Begin PBXFrameworksBuildPhase section */")
    for key in ["ios_frameworks", "preview_frameworks", "watch_frameworks", "live_activity_frameworks", "test_frameworks", "ui_frameworks"]:
        lines.append(f"\t\t{phases[key]} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
    lines.append("/* End PBXFrameworksBuildPhase section */\n")

    lines.append("/* Begin PBXGroup section */")
    for group, names in files.items():
        children = ", ".join(refs[f"{group}/{name}"] for name in names)
        lines.append(f"\t\t{groups[group]} /* {group} */ = {{isa = PBXGroup; children = ({children}, ); path = {q(group)}; sourceTree = \"<group>\"; }};")
    ext_children = ", ".join(refs[name] for name in external)
    lines.append(f"\t\t{groups['External Resources']} = {{isa = PBXGroup; children = ({ext_children}, ); name = \"External Resources\"; sourceTree = \"<group>\"; }};")
    product_children = ", ".join(products.values())
    lines.append(f"\t\t{groups['Products']} = {{isa = PBXGroup; children = ({product_children}, ); name = Products; sourceTree = \"<group>\"; }};")
    main_children = ", ".join(groups[name] for name in ["Shared", "iPhone", "Watch", "LiveActivity", "Tests", "UITests", "Resources", "External Resources", "Products"])
    lines.append(f"\t\t{main_group} = {{isa = PBXGroup; children = ({main_children}, ); sourceTree = \"<group>\"; }};")
    lines.append("/* End PBXGroup section */\n")

    lines.append("/* Begin PBXNativeTarget section */")
    target_specs = {
        "ios": ("KrisCoach", [phases['ios_sources'], phases['ios_frameworks'], phases['ios_resources'], phases['ios_embed_watch'], phases['ios_embed_extensions']], [watch_dependency, live_activity_dependency], products['KrisCoach.app'], "com.apple.product-type.application"),
        "preview": ("KrisCoach Preview", [phases['preview_sources'], phases['preview_frameworks'], phases['preview_resources']], [], products['KrisCoach Preview.app'], "com.apple.product-type.application"),
        "watch": ("KrisCoach Watch", [phases['watch_sources'], phases['watch_frameworks'], phases['watch_app_resources']], [], products['Kris.app'], "com.apple.product-type.application"),
        "live_activity": ("KrisLiveActivity", [phases['live_activity_sources'], phases['live_activity_frameworks'], phases['live_activity_resources']], [], products['KrisLiveActivity.appex'], "com.apple.product-type.app-extension"),
        "tests": ("KrisCoachTests", [phases['test_sources'], phases['test_frameworks'], phases['test_resources']], [test_dependency], products['KrisCoachTests.xctest'], "com.apple.product-type.bundle.unit-test"),
        "uitests": ("KrisCoachUITests", [phases['ui_sources'], phases['ui_frameworks'], phases['ui_resources']], [ui_dependency], products['KrisCoachUITests.xctest'], "com.apple.product-type.bundle.ui-testing"),
    }
    for key, (name, phase_ids, deps, product, product_type) in target_specs.items():
        lines.append(f"\t\t{targets[key]} /* {name} */ = {{isa = PBXNativeTarget; buildConfigurationList = {configs[key][2]}; buildPhases = {array(phase_ids)}; buildRules = (); dependencies = {array(deps)}; name = {q(name)}; productName = {q(name)}; productReference = {product}; productType = {q(product_type)}; }};")
    lines.append("/* End PBXNativeTarget section */\n")

    lines.extend(["/* Begin PBXProject section */",
        f"\t\t{project_id} /* Project object */ = {{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2660; LastUpgradeCheck = 2660; TargetAttributes = {{{targets['ios']} = {{CreatedOnToolsVersion = 26.0; DevelopmentTeam = DN45UAAJKP; }}; {targets['preview']} = {{CreatedOnToolsVersion = 26.0; DevelopmentTeam = DN45UAAJKP; }}; {targets['watch']} = {{CreatedOnToolsVersion = 26.0; DevelopmentTeam = DN45UAAJKP; }}; {targets['live_activity']} = {{CreatedOnToolsVersion = 26.0; DevelopmentTeam = DN45UAAJKP; }}; {targets['tests']} = {{CreatedOnToolsVersion = 26.0; TestTargetID = {targets['preview']}; }}; {targets['uitests']} = {{CreatedOnToolsVersion = 26.0; TestTargetID = {targets['preview']}; }}; }}; }}; buildConfigurationList = {configs['project'][2]}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, \"zh-Hans\"); mainGroup = {main_group}; productRefGroup = {groups['Products']}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({targets['ios']}, {targets['preview']}, {targets['watch']}, {targets['live_activity']}, {targets['tests']}, {targets['uitests']}); }};",
        "/* End PBXProject section */\n"])

    lines.append("/* Begin PBXResourcesBuildPhase section */")
    resource_map = {
        "ios_resources": list(resource_build.values()), "preview_resources": list(preview_resource_build.values()), "watch_app_resources": list(watch_resource_build.values()), "live_activity_resources": [],
        "test_resources": list(test_resource_build.values()), "ui_resources": [],
    }
    for key, values in resource_map.items():
        lines.append(f"\t\t{phases[key]} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(values)}; runOnlyForDeploymentPostprocessing = 0; }};")
    lines.append("/* End PBXResourcesBuildPhase section */\n")
    lines.append("/* Begin PBXSourcesBuildPhase section */")
    for target, paths in source_lists.items():
        key = {"ios": "ios_sources", "preview": "preview_sources", "watch": "watch_sources", "live_activity": "live_activity_sources", "tests": "test_sources", "uitests": "ui_sources"}[target]
        values = [build_files[(target, path)] for path in paths]
        lines.append(f"\t\t{phases[key]} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({', '.join(values)}, ); runOnlyForDeploymentPostprocessing = 0; }};")
    lines.append("/* End PBXSourcesBuildPhase section */\n")
    lines.extend(["/* Begin PBXTargetDependency section */",
        f"\t\t{watch_dependency} = {{isa = PBXTargetDependency; target = {targets['watch']}; targetProxy = {watch_proxy}; }};",
        f"\t\t{live_activity_dependency} = {{isa = PBXTargetDependency; target = {targets['live_activity']}; targetProxy = {live_activity_proxy}; }};",
        f"\t\t{test_dependency} = {{isa = PBXTargetDependency; target = {targets['preview']}; targetProxy = {test_proxy}; }};",
        f"\t\t{ui_dependency} = {{isa = PBXTargetDependency; target = {targets['preview']}; targetProxy = {ui_proxy}; }};",
        "/* End PBXTargetDependency section */\n"])

    def settings(items: dict[str, str]) -> str:
        return " ".join(f"{key} = {value};" for key, value in items.items())

    common = {"CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
    project_debug = {**common, "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_PREPROCESSOR_DEFINITIONS": '"DEBUG=1"'}
    project_release = {**common, "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "SWIFT_COMPILATION_MODE": "wholemodule"}
    ios = {
        "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "DN45UAAJKP", "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "iPhone/Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.albertdaisy.kriscoach", "PRODUCT_NAME": '"$(TARGET_NAME)"', "SDKROOT": "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "TARGETED_DEVICE_FAMILY": '"1"', "CODE_SIGN_ENTITLEMENTS": "iPhone/KrisCoach.entitlements",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "KRIS_AI_GATEWAY_URL": '""',
        "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "9",
    }
    preview = {
        **ios,
        "PRODUCT_BUNDLE_IDENTIFIER": "com.albertdaisy.kriscoach.preview",
        "PRODUCT_NAME": '"KrisCoach Preview"',
        "PRODUCT_MODULE_NAME": "KrisCoach",
    }
    watch = {
        "CODE_SIGN_ENTITLEMENTS": "Watch/KrisCoachWatch.entitlements", "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "DN45UAAJKP", "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "Watch/Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.albertdaisy.kriscoach.watchkitapp", "PRODUCT_NAME": '"Kris"', "SDKROOT": "watchos",
        "WATCHOS_DEPLOYMENT_TARGET": "26.0", "TARGETED_DEVICE_FAMILY": '"4"', "SKIP_INSTALL": "YES",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "9",
    }
    live_activity = {
        "APPLICATION_EXTENSION_API_ONLY": "YES", "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "DN45UAAJKP",
        "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "LiveActivity/Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.albertdaisy.kriscoach.liveactivity", "PRODUCT_NAME": '"$(TARGET_NAME)"', "SDKROOT": "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "TARGETED_DEVICE_FAMILY": '"1"', "SKIP_INSTALL": "YES",
        "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "9",
    }
    tests = {
        "GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "com.albertdaisy.kriscoach.tests", "SDKROOT": "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/KrisCoach Preview.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/KrisCoach Preview"',
        "BUNDLE_LOADER": '"$(TEST_HOST)"', "PRODUCT_NAME": '"$(TARGET_NAME)"',
    }
    uitests = {
        "GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "com.albertdaisy.kriscoach.uitests", "SDKROOT": "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "TEST_TARGET_NAME": '"KrisCoach Preview"', "PRODUCT_NAME": '"$(TARGET_NAME)"',
    }
    config_values = {"project": (project_debug, project_release), "ios": (ios, ios), "preview": (preview, preview), "watch": (watch, watch), "live_activity": (live_activity, live_activity), "tests": (tests, tests), "uitests": (uitests, uitests)}
    lines.append("/* Begin XCBuildConfiguration section */")
    for key, (debug_id, release_id, _) in configs.items():
        debug_settings, release_settings = config_values[key]
        lines.append(f"\t\t{debug_id} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{{settings(debug_settings)}}}; name = Debug; }};")
        lines.append(f"\t\t{release_id} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{{settings(release_settings)}}}; name = Release; }};")
    lines.append("/* End XCBuildConfiguration section */\n")
    lines.append("/* Begin XCConfigurationList section */")
    for key, (debug_id, release_id, list_id) in configs.items():
        lines.append(f"\t\t{list_id} = {{isa = XCConfigurationList; buildConfigurations = ({debug_id}, {release_id}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
    lines.append("/* End XCConfigurationList section */")
    lines.extend(["\t};", f"\trootObject = {project_id} /* Project object */;", "}"])
    (PROJECT / "project.pbxproj").write_text("\n".join(lines) + "\n", encoding="utf-8")
    write_main_scheme(targets)
    print(PROJECT)


if __name__ == "__main__":
    main()
