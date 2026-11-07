"""根据已有 Swift 源码生成可直接打开的 Xcode 工程。"""

import hashlib
import json
import plistlib
import sys
from pathlib import Path
from xml.etree.ElementTree import Element, SubElement, tostring


ROOT = Path(__file__).resolve().parents[1] / "ios"
OBJECTS = {}
sys.stdout.reconfigure(encoding="utf-8")


def identifier(value):
    return hashlib.sha1(value.encode("utf-8")).hexdigest()[:24].upper()


def add(key, isa, **values):
    reference = identifier(key)
    OBJECTS[reference] = {"isa": isa, **values}
    return reference


def serialize(value, level=0):
    padding = "\t" * level
    if isinstance(value, dict):
        items = [f"{padding}\t{json.dumps(key)} = {serialize(item, level + 1)};" for key, item in value.items()]
        return "{\n" + "\n".join(items) + "\n" + padding + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f"{padding}\t{serialize(item, level + 1)},\n" for item in value) + padding + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


def source_group(directory):
    children, swift, resources = [], [], []
    for path in sorted(directory.iterdir()):
        relative = path.relative_to(ROOT).as_posix()
        if path.name.endswith(".xcassets"):
            reference = add(relative, "PBXFileReference", lastKnownFileType="folder.assetcatalog", path=path.name, sourceTree="<group>")
            children.append(reference)
            resources.append(reference)
        elif path.is_dir():
            group, sources, files = source_group(path)
            children.append(group)
            swift.extend(sources)
            resources.extend(files)
        elif path.suffix in (".swift", ".plist", ".entitlements", ".xcprivacy"):
            file_type = "sourcecode.swift" if path.suffix == ".swift" else "text.plist.xml"
            reference = add(relative, "PBXFileReference", lastKnownFileType=file_type, path=path.name, sourceTree="<group>")
            children.append(reference)
            if path.suffix == ".swift":
                swift.append(reference)
            elif path.suffix == ".xcprivacy":
                resources.append(reference)
    group = add(str(directory.relative_to(ROOT)), "PBXGroup", children=children, path=directory.name, sourceTree="<group>")
    return group, swift, resources


def build_phase(name, isa, references):
    files = [add(name + ":" + reference, "PBXBuildFile", fileRef=reference) for reference in references]
    return add(name, isa, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)


def configurations(name, settings):
    values = []
    for configuration in ("Debug", "Release"):
        current = dict(settings)
        current["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if configuration == "Debug" else "-O"
        current["DEBUG_INFORMATION_FORMAT"] = "dwarf" if configuration == "Debug" else "dwarf-with-dsym"
        if configuration == "Debug":
            current["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            current["ENABLE_TESTABILITY"] = "YES"
        if name == "BingJian":
            current["APNS_ENVIRONMENT"] = "development" if configuration == "Debug" else "production"
        values.append(add(name + configuration, "XCBuildConfiguration", buildSettings=current, name=configuration))
    return add(name + "Configurations", "XCConfigurationList", buildConfigurations=values, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


def resources():
    base = {
        "CFBundleDevelopmentRegion": "zh_CN", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.6", "CFBundleVersion": "7",
        "NSHealthShareUsageDescription": "读取你授权的步数、消耗、体重、运动、心率和睡眠，用于个人记录与趋势分析。",
        "NSHealthUpdateUsageDescription": "健康数据以你的明确授权为前提，当前版本优先保存本机记录。",
    }
    write_plist(ROOT / "BingJian" / "Info.plist", {
        **base, "CFBundleDisplayName": "并肩", "LSRequiresIPhoneOS": True,
        "NSCameraUsageDescription": "拍摄餐食照片以辅助记录，也可拍摄挑战邀请码。",
        "NSPhotoLibraryUsageDescription": "选择你指定的餐食照片，用于个人饮食记录。",
        "NSLocalNetworkUsageDescription": "连接你配置的私有服务器，进行记录同步和伙伴共享。",
        # 后台地址由用户配置，允许显式 HTTP；不能同时添加会覆盖此例外的 NSAllowsLocalNetworking。
        "NSBonjourServices": ["_fatloss._tcp"], "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        "UIBackgroundModes": ["fetch"], "BGTaskSchedulerPermittedIdentifiers": ["$(PRODUCT_BUNDLE_IDENTIFIER).refresh"],
        "CFBundleURLTypes": [{"CFBundleURLName": "com.bingjian.health.invite", "CFBundleURLSchemes": ["bingjian"]}],
        "LSSupportsOpeningDocumentsInPlace": True,
        "CFBundleDocumentTypes": [{"CFBundleTypeName": "并肩加密恢复包", "LSHandlerRank": "Owner",
                                  "LSItemContentTypes": ["com.bingjian.archive"]}],
        "UTExportedTypeDeclarations": [{"UTTypeIdentifier": "com.bingjian.archive", "UTTypeDescription": "并肩加密恢复包",
                                        "UTTypeConformsTo": ["public.data"],
                                        "UTTypeTagSpecification": {"public.filename-extension": ["bjar"]}}],
    })
    write_plist(ROOT / "BingJianWatch" / "Info.plist", {
        **base, "CFBundleDisplayName": "并肩", "WKApplication": True,
        "WKCompanionAppBundleIdentifier": "$(APP_BUNDLE_IDENTIFIER)", "WKRunsIndependentlyOfCompanionApp": True,
    })
    write_plist(ROOT / "BingJian" / "BingJian.entitlements", {
        "com.apple.developer.healthkit": True,
        "com.apple.developer.healthkit.background-delivery": True,
        "aps-environment": "$(APNS_ENVIRONMENT)",
    })
    write_plist(ROOT / "BingJianWatch" / "BingJianWatch.entitlements", {
        "com.apple.developer.healthkit": True,
    })
    write_plist(ROOT / "BingJian" / "Resigning.entitlements", {
        "com.apple.developer.healthkit": True,
        "com.apple.developer.healthkit.background-delivery": True,
    })
    privacy = {
        "NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [],
        "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]},
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons": ["C617.1"]},
        ],
    }
    write_plist(ROOT / "BingJian" / "PrivacyInfo.xcprivacy", privacy)
    write_plist(ROOT / "BingJianWatch" / "PrivacyInfo.xcprivacy", privacy)


def app_icons():
    from PIL import Image, ImageDraw
    icon = Image.new("RGB", (1024, 1024), "#EFF6F7")
    draw = ImageDraw.Draw(icon)
    draw.rounded_rectangle((240, 206, 446, 804), radius=103, fill="#0D6B6A")
    draw.rounded_rectangle((578, 344, 784, 804), radius=103, fill="#91BFB0")
    draw.ellipse((608, 174, 754, 320), fill="#ED9E65")
    for target, platform in (("BingJian", "ios"), ("BingJianWatch", "watchos")):
        assets = ROOT / target / "Assets.xcassets"
        catalog = assets / "AppIcon.appiconset"
        catalog.mkdir(parents=True, exist_ok=True)
        (assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")
        icon.save(catalog / "AppIcon.png")
        (catalog / "Contents.json").write_text(json.dumps({
            "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        }, indent=2), encoding="utf-8")


def scheme(project, app_id, tests_id):
    root = Element("Scheme", {"LastUpgradeVersion": "1600", "version": "1.7"})
    build = SubElement(root, "BuildAction", {"parallelizeBuildables": "YES", "buildImplicitDependencies": "YES"})
    entries = SubElement(build, "BuildActionEntries")
    entry = SubElement(entries, "BuildActionEntry", {"buildForTesting": "YES", "buildForRunning": "YES",
        "buildForProfiling": "YES", "buildForArchiving": "YES", "buildForAnalyzing": "YES"})

    def reference(parent, target, name, product):
        SubElement(parent, "BuildableReference", {"BuildableIdentifier": "primary", "BlueprintIdentifier": target,
            "BuildableName": product, "BlueprintName": name, "ReferencedContainer": "container:BingJian.xcodeproj"})

    reference(entry, app_id, "BingJian", "BingJian.app")
    testing = SubElement(root, "TestAction", {"buildConfiguration": "Debug", "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
        "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB", "shouldUseLaunchSchemeArgsEnv": "YES"})
    testables = SubElement(testing, "Testables")
    testable = SubElement(testables, "TestableReference", {"skipped": "NO"})
    reference(testable, tests_id, "BingJianTests", "BingJianTests.xctest")
    launch = SubElement(root, "LaunchAction", {"buildConfiguration": "Debug", "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
        "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB", "launchStyle": "0", "useCustomWorkingDirectory": "NO",
        "ignoresPersistentStateOnLaunch": "NO", "debugDocumentVersioning": "YES", "debugServiceExtension": "internal", "allowLocationSimulation": "YES"})
    runnable = SubElement(launch, "BuildableProductRunnable", {"runnableDebuggingMode": "0"})
    reference(runnable, app_id, "BingJian", "BingJian.app")
    profile = SubElement(root, "ProfileAction", {"buildConfiguration": "Release", "shouldUseLaunchSchemeArgsEnv": "YES", "useCustomWorkingDirectory": "NO"})
    reference(SubElement(profile, "BuildableProductRunnable", {"runnableDebuggingMode": "0"}), app_id, "BingJian", "BingJian.app")
    SubElement(root, "AnalyzeAction", {"buildConfiguration": "Debug"})
    SubElement(root, "ArchiveAction", {"buildConfiguration": "Release", "revealArchiveInOrganizer": "YES"})
    folder = project / "xcshareddata" / "xcschemes"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "BingJian.xcscheme").write_bytes(b'<?xml version="1.0" encoding="UTF-8"?>\n' + tostring(root, encoding="utf-8"))


def main():
    resources()
    app_icons()
    project_id = identifier("Project")
    groups, products, target_ids = [], [], []
    specifications = [
        ("BingJianWatch", "watchos", "$(APP_BUNDLE_IDENTIFIER).watchkitapp", "com.apple.product-type.application"),
        ("BingJian", "iphoneos", "$(APP_BUNDLE_IDENTIFIER)", "com.apple.product-type.application"),
        ("BingJianTests", "iphoneos", "$(APP_BUNDLE_IDENTIFIER).tests", "com.apple.product-type.bundle.unit-test"),
    ]
    for name, sdk, bundle, product_type in specifications:
        directory = ROOT / name
        directory.mkdir(exist_ok=True)
        group, sources, resource_files = source_group(directory)
        if name == "BingJianWatch":
            weight_unit = add("SharedWeightUnit", "PBXFileReference", lastKnownFileType="sourcecode.swift",
                              path="BingJian/Domain/WeightUnit.swift", sourceTree="SOURCE_ROOT")
            OBJECTS[group]["children"].append(weight_unit)
            sources.append(weight_unit)
        if name == "BingJian":
            schema = add("FoodSchema", "PBXFileReference", lastKnownFileType="text.json",
                         path="../backend/app/resources/food_schema.json", sourceTree="SOURCE_ROOT")
            OBJECTS[group]["children"].append(schema)
            resource_files.append(schema)
        groups.append(group)
        suffix = ".xctest" if name.endswith("Tests") else ".app"
        product = add(name + "Product", "PBXFileReference", explicitFileType="wrapper.cfbundle" if suffix == ".xctest" else "wrapper.application",
                      includeInIndex=0, path=name + suffix, sourceTree="BUILT_PRODUCTS_DIR")
        products.append(product)
        phases = [build_phase(name + "Sources", "PBXSourcesBuildPhase", sources),
                  build_phase(name + "Frameworks", "PBXFrameworksBuildPhase", []),
                  build_phase(name + "Resources", "PBXResourcesBuildPhase", resource_files)]
        dependencies = []
        settings = {
            "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": bundle, "SDKROOT": sdk,
            "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "minimal", "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": "7", "MARKETING_VERSION": "0.1.6", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "CLANG_ENABLE_MODULES": "YES", "GENERATE_INFOPLIST_FILE": "NO",
        }
        if name == "BingJianWatch":
            settings.update({"WATCHOS_DEPLOYMENT_TARGET": "10.0", "TARGETED_DEVICE_FAMILY": "4",
                             "SUPPORTED_PLATFORMS": "watchos watchsimulator", "SKIP_INSTALL": "YES",
                             "INFOPLIST_FILE": name + "/Info.plist", "CODE_SIGN_ENTITLEMENTS": name + "/" + name + ".entitlements",
                             "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"})
        elif name == "BingJian":
            settings.update({"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "TARGETED_DEVICE_FAMILY": "1",
                             "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO",
                             "INFOPLIST_FILE": name + "/Info.plist", "CODE_SIGN_ENTITLEMENTS": name + "/" + name + ".entitlements",
                             "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "APNS_ENVIRONMENT": "development",
                             "CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]": name + "/Simulator.entitlements",
                             "OTHER_LDFLAGS": ["$(inherited)", "-lsqlite3"]})
            watch_product = identifier("BingJianWatchProduct")
            embedded = add("EmbedWatchFile", "PBXBuildFile", fileRef=watch_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
            phases.append(add("EmbedWatch", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="$(CONTENTS_FOLDER_PATH)/Watch",
                              dstSubfolderSpec=16, files=[embedded], name="Embed Watch Content", runOnlyForDeploymentPostprocessing=0))
            proxy = add("WatchProxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1,
                        remoteGlobalIDString=identifier("BingJianWatchTarget"), remoteInfo="BingJianWatch")
            dependencies.append(add("WatchDependency", "PBXTargetDependency", target=identifier("BingJianWatchTarget"), targetProxy=proxy))
        else:
            settings.update({"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "GENERATE_INFOPLIST_FILE": "YES",
                             "TARGETED_DEVICE_FAMILY": "1", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/BingJian.app/BingJian",
                             "BUNDLE_LOADER": "$(TEST_HOST)", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"})
            proxy = add("TestHostProxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1,
                        remoteGlobalIDString=identifier("BingJianTarget"), remoteInfo="BingJian")
            dependencies.append(add("TestDependency", "PBXTargetDependency", target=identifier("BingJianTarget"), targetProxy=proxy))
        target_ids.append(add(name + "Target", "PBXNativeTarget", buildConfigurationList=configurations(name, settings),
                              buildPhases=phases, buildRules=[], dependencies=dependencies, name=name,
                              productName=name, productReference=product, productType=product_type))
    products_group = add("Products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
    main_group = add("MainGroup", "PBXGroup", children=groups + [products_group], sourceTree="<group>")
    add("Project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600"},
        buildConfigurationList=configurations("Project", {"CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0",
                                                         "APP_BUNDLE_IDENTIFIER": "com.bingjian.health"}),
        compatibilityVersion="Xcode 14.0", developmentRegion="zh_CN", hasScannedForEncodings=0, knownRegions=["zh_CN", "en", "Base"],
        mainGroup=main_group, productRefGroup=products_group, projectDirPath="", projectRoot="", targets=target_ids)
    project = ROOT / "BingJian.xcodeproj"
    project.mkdir(exist_ok=True)
    document = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": OBJECTS, "rootObject": project_id}
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(document) + "\n", encoding="utf-8")
    scheme(project, identifier("BingJianTarget"), identifier("BingJianTestsTarget"))
    print(f"已生成工程，源文件数量 {len(list(ROOT.rglob('*.swift')))}")


if __name__ == "__main__":
    main()
