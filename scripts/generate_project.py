#!/usr/bin/env python3
"""Generate deterministic Xcode project with app, keyboard and Live Activity targets."""
from pathlib import Path
import hashlib, sys
fluid = '--without-fluidaudio' not in sys.argv
team = next((arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--team=')), '')
objects={}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def obj(name,text): objects[uid(name)]=text; return uid(name)
def ref(name): return uid(name)
def arr(items): return '(' + ', '.join(items) + ',)' if items else '()'
for name in ['LocalScribeApp','SharedKeyboard','LocalScribeKeyboard','SharedActivity','LocalScribeActivityWidget']:
 obj(name, f'isa = PBXFileSystemSynchronizedRootGroup; path = {name}; sourceTree = "<group>";')
obj('manifest','isa = PBXFileReference; lastKnownFileType = text.json; path = Resources/model-integrity.json; sourceTree = "<group>";')
obj('benchmark','isa = PBXFileReference; lastKnownFileType = folder; path = Resources/benchmark; sourceTree = "<group>";')
obj('benchmarkBuild',f'isa = PBXBuildFile; fileRef = {ref("benchmark")};')
obj('legal','isa = PBXFileReference; lastKnownFileType = folder; path = Resources/legal; sourceTree = "<group>";')
obj('legalBuild',f'isa = PBXBuildFile; fileRef = {ref("legal")};')
obj('manifestBuild',f'isa = PBXBuildFile; fileRef = {ref("manifest")};')
obj('appProduct','isa = PBXFileReference; explicitFileType = wrapper.application; path = LocalScribe.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('keyboardProduct','isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = LocalScribeKeyboard.appex; sourceTree = BUILT_PRODUCTS_DIR;')
obj('widgetProduct','isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = LocalScribeActivityWidget.appex; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products',f'isa = PBXGroup; children = {arr([ref("appProduct"),ref("keyboardProduct"),ref("widgetProduct")])}; name = Products; sourceTree = "<group>";')
obj('root',f'isa = PBXGroup; children = {arr([ref(n) for n in ["LocalScribeApp","LocalScribeKeyboard","SharedKeyboard","SharedActivity","LocalScribeActivityWidget","manifest","benchmark","legal","products"]])}; sourceTree = "<group>";')
obj('coreRef','isa = XCLocalSwiftPackageReference; relativePath = .;')
obj('coreProduct',f'isa = XCSwiftPackageProductDependency; package = {ref("coreRef")}; productName = LocalScribeCore;')
obj('coreBuild',f'isa = PBXBuildFile; productRef = {ref("coreProduct")};')
if fluid:
 obj('fluidRef','isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/FluidInference/FluidAudio.git"; requirement = { kind = exactVersion; version = 0.17.5; };')
 obj('fluidProduct',f'isa = XCSwiftPackageProductDependency; package = {ref("fluidRef")}; productName = FluidAudio;')
 obj('fluidBuild',f'isa = PBXBuildFile; productRef = {ref("fluidProduct")};')
 obj('moonshineRef','isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/moonshine-ai/moonshine-swift.git"; requirement = { kind = exactVersion; version = 0.1.5; };')
 obj('moonshineProduct',f'isa = XCSwiftPackageProductDependency; package = {ref("moonshineRef")}; productName = MoonshineVoice;')
 obj('moonshineBuild',f'isa = PBXBuildFile; productRef = {ref("moonshineProduct")};')
obj('embedKeyboard',f'isa = PBXBuildFile; fileRef = {ref("keyboardProduct")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy, ); }};')
obj('embedWidget',f'isa = PBXBuildFile; fileRef = {ref("widgetProduct")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy, ); }};')
obj('embedPhase',f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = {arr([ref("embedKeyboard"),ref("embedWidget")])}; name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
obj('keyboardProxy',f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("keyboardTarget")}; remoteInfo = LocalScribeKeyboard;')
obj('keyboardDep',f'isa = PBXTargetDependency; target = {ref("keyboardTarget")}; targetProxy = {ref("keyboardProxy")};')
obj('widgetProxy',f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("widgetTarget")}; remoteInfo = LocalScribeActivityWidget;')
obj('widgetDep',f'isa = PBXTargetDependency; target = {ref("widgetTarget")}; targetProxy = {ref("widgetProxy")};')
for target in ['app','keyboard','widget']:
 obj(target+'Sources','isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
 libs=[ref('coreBuild')]+([ref('fluidBuild'), ref('moonshineBuild')] if fluid else []) if target=='app' else []
 obj(target+'Frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {arr(libs)}; runOnlyForDeploymentPostprocessing = 0;')
 obj(target+'Resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {arr([ref("manifestBuild"),ref("benchmarkBuild"),ref("legalBuild")] if target=="app" else [])}; runOnlyForDeploymentPostprocessing = 0;')
 configs=[]
 for mode in ['Debug','Release']:
  prefix={'app':'App','keyboard':'Keyboard','widget':'ActivityWidget'}[target]
  suffix={'app':'','keyboard':'.keyboard','widget':'.activity'}[target]
  values={'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'18.0','SWIFT_VERSION':'6.0','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'Configuration/'+prefix+'-Info.plist','PRODUCT_BUNDLE_IDENTIFIER':'com.devesh.localscribe.ios'+suffix,'CURRENT_PROJECT_VERSION':'8','MARKETING_VERSION':'0.6.1','SWIFT_STRICT_CONCURRENCY':'complete','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'+(' @executable_path/../../Frameworks' if target!='app' else ''),'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym'}
  if target!='widget': values['CODE_SIGN_ENTITLEMENTS']='Configuration/'+prefix+'.entitlements'
  if team: values['DEVELOPMENT_TEAM'] = team
  if target=='app': values['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  if target!='app': values.update({'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES'})
  if mode=='Debug': values['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG $(inherited)'
  configs.append(obj(target+mode,'isa = XCBuildConfiguration; buildSettings = {'+' '.join(f'{k} = "{v}";' for k,v in values.items())+f'}}; name = {mode};'))
 obj(target+'ConfigList',f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
 phases=[ref(target+p) for p in ['Sources','Frameworks','Resources']]+([ref('embedPhase')] if target=='app' else [])
 name={'app':'LocalScribe','keyboard':'LocalScribeKeyboard','widget':'LocalScribeActivityWidget'}[target]
 products=[ref('coreProduct')]+([ref('fluidProduct'), ref('moonshineProduct')] if fluid else []) if target=='app' else []
 groups={'app':['LocalScribeApp','SharedKeyboard','SharedActivity'],'keyboard':['LocalScribeKeyboard','SharedKeyboard'],'widget':['LocalScribeActivityWidget','SharedActivity']}[target]
 obj(target+'Target',f'isa = PBXNativeTarget; buildConfigurationList = {ref(target+"ConfigList")}; buildPhases = {arr(phases)}; buildRules = (); dependencies = {arr([ref("keyboardDep"),ref("widgetDep")] if target=="app" else [])}; fileSystemSynchronizedGroups = {arr([ref(group) for group in groups])}; name = {name}; packageProductDependencies = {arr(products)}; productName = {name}; productReference = {ref(target+"Product")}; productType = "com.apple.product-type.{"application" if target=="app" else "app-extension"}";')
configs=[]
for mode in ['Debug','Release']:
 configs.append(obj('project'+mode,f'isa = XCBuildConfiguration; buildSettings = {{ CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; }}; name = {mode};'))
obj('projectConfigList',f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; TargetAttributes = {{ {ref("appTarget")} = {{ CreatedOnToolsVersion = 27.0; SystemCapabilities = {{ com.apple.ApplicationGroups.iOS = {{enabled = 1;}}; }}; }}; {ref("keyboardTarget")} = {{ CreatedOnToolsVersion = 27.0; SystemCapabilities = {{ com.apple.ApplicationGroups.iOS = {{enabled = 1;}}; }}; }}; {ref("widgetTarget")} = {{ CreatedOnToolsVersion = 27.0; }}; }}; }}; buildConfigurationList = {ref("projectConfigList")}; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {ref("root")}; minimizedProjectReferenceProxies = 1; packageReferences = {arr([ref("coreRef")]+([ref("fluidRef"), ref("moonshineRef")] if fluid else []))}; preferredProjectObjectVersion = 77; productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; targets = {arr([ref("appTarget"),ref("keyboardTarget"),ref("widgetTarget")])};')
Path('LocalScribe.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{\n archiveVersion = 1; classes = {}; objectVersion = 77;\n objects = {\n'+''.join(f' {key} = {{ {value} }};\n' for key,value in sorted(objects.items()))+f' }};\n rootObject = {ref("project")};\n}}\n')
Path('LocalScribe.xcodeproj/xcshareddata/xcschemes/LocalScribe.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref('appTarget')}" BuildableName="LocalScribe.app" BlueprintName="LocalScribe" ReferencedContainer="container:LocalScribe.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref('appTarget')}" BuildableName="LocalScribe.app" BlueprintName="LocalScribe" ReferencedContainer="container:LocalScribe.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
