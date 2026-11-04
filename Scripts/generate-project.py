#!/usr/bin/env python3
"""Generate Xcode targets for macOS, iOS, Share and the Safari web extension."""
from pathlib import Path
import hashlib, plistlib
root=Path(__file__).resolve().parents[1]
objects={}
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(key_name,isa,**fields):
 key=ident(key_name); objects[key]={'isa':isa,**fields}; return key

def quote(value):
 import json
 if isinstance(value,str): return json.dumps(value)
 if isinstance(value,list): return '('+','.join(quote(x) for x in value)+')'
 if isinstance(value,dict): return '{'+';'.join(quote(k)+' = '+quote(v) for k,v in value.items())+';}'
 return str(value)
package=add('package','XCLocalSwiftPackageReference',relativePath='.')
products=[]; sources=[]; targets=[]
for name,source,bundle,platform,kind in [
 ('Research Library','Sources/ResearchLibrary/App.swift','org.researchlibrary.mac','macosx','application'),
 ('Research Library Capture','Apple/iOS/ResearchLibraryCaptureApp.swift','org.researchlibrary.capture','iphoneos','application'),
 ('Research Library Share','Apple/ShareExtension/ShareViewController.swift','org.researchlibrary.capture.share','iphoneos','app-extension')]:
 ref=add(name+'source','PBXFileReference',lastKnownFileType='sourcecode.swift',path=source,sourceTree='<group>');sources.append(ref)
 build=add(name+'buildsource','PBXBuildFile',fileRef=ref)
 src=add(name+'sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[build],runOnlyForDeploymentPostprocessing=0)
 dependency=add(name+'packageProduct','XCSwiftPackageProductDependency',package=package,productName='ResearchCore')
 link=add(name+'link','PBXBuildFile',productRef=dependency)
 framework=add(name+'frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[link],runOnlyForDeploymentPostprocessing=0)
 asset=add(name+'asset','PBXFileReference',lastKnownFileType='folder.assetcatalog',path='Apple/Assets.xcassets',sourceTree='<group>');sources.append(asset)
 assetBuild=add(name+'assetBuild','PBXBuildFile',fileRef=asset)
 shortcuts=add(name+'shortcuts','PBXFileReference',lastKnownFileType='text.json.xcstrings',path='Apple/AppShortcuts.xcstrings',sourceTree='<group>');sources.append(shortcuts)
 shortcutsBuild=add(name+'shortcutsBuild','PBXBuildFile',fileRef=shortcuts)
 resource=add(name+'resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[] if kind=='app-extension' else [assetBuild,shortcutsBuild],runOnlyForDeploymentPostprocessing=0)
 suffix='appex' if kind=='app-extension' else 'app'
 product=add(name+'product','PBXFileReference',explicitFileType='wrapper.app-extension' if suffix=='appex' else 'wrapper.application',path=name+'.'+suffix,sourceTree='BUILT_PRODUCTS_DIR');products.append(product)
 plist_path='Apple/'+('ShareExtension/Info.plist' if kind=='app-extension' else ('macOS-Info.plist' if platform=='macosx' else 'iOS/Info.plist'))
 plist={'CFBundleName':name,'CFBundleDisplayName':'Research Library','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundlePackageType':'XPC!' if suffix=='appex' else 'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','CFBundleDevelopmentRegion':'en'}
 if platform=='macosx': plist.update({'LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,'CFBundleURLTypes':[{'CFBundleURLName':'org.researchlibrary.capture','CFBundleURLSchemes':['researchlibrary']}]})
 elif suffix=='app': plist.update({'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':True},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']})
 else: plist['NSExtension']={'NSExtensionPointIdentifier':'com.apple.share-services','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).ShareViewController','NSExtensionAttributes':{'NSExtensionActivationRule':{'NSExtensionActivationSupportsWebURLWithMaxCount':10,'NSExtensionActivationSupportsFileWithMaxCount':10,'NSExtensionActivationSupportsText':True}}}
 (root/plist_path).write_bytes(plistlib.dumps(plist))
 entitlement='Apple/'+('macOS.entitlements' if platform=='macosx' else 'iOS.entitlements')
 ents={'com.apple.security.application-groups':['group.org.researchlibrary.app']}
 if platform=='macosx': ents.update({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-write':True,'com.apple.security.network.client':True,'com.apple.security.files.bookmarks.app-scope':True})
 (root/entitlement).write_bytes(plistlib.dumps(ents))
 configs=[]
 for mode in ['Debug','Release']:
  settings={'PRODUCT_NAME':name,'PRODUCT_BUNDLE_IDENTIFIER':bundle,'INFOPLIST_FILE':plist_path,'SDKROOT':platform,'SWIFT_VERSION':'5.0','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_ENTITLEMENTS':entitlement,'MACOSX_DEPLOYMENT_TARGET':'14.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0','TARGETED_DEVICE_FAMILY':'1,2','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'],'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else '','ONLY_ACTIVE_ARCH':'YES' if mode=='Debug' else 'NO','ENABLE_APP_INTENTS_METADATA_GENERATION':'YES','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon' if kind!='app-extension' else ''}
  if suffix=='appex':settings.update({'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES'})
  configs.append(add(name+mode,'XCBuildConfiguration',name=mode,buildSettings=settings))
 cl=add(name+'configs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
 target=add(name+'target','PBXNativeTarget',name=name,productName=name,productReference=product,productType='com.apple.product-type.'+kind,buildConfigurationList=cl,buildPhases=[src,framework,resource],buildRules=[],dependencies=[],packageProductDependencies=[dependency]);targets.append(target)
# Keep the native PDF reader in generated projects, too.
readerRef=add('readerSource','PBXFileReference',lastKnownFileType='sourcecode.swift',path='Sources/ResearchLibrary/Reader.swift',sourceTree='<group>');sources.append(readerRef)
readerBuild=add('readerBuild','PBXBuildFile',fileRef=readerRef)
objects[ident('Research Librarysources')]['files'].append(readerBuild)
# Safari passes bounded capture links to the containing app; it never receives the library bookmark.
safariName='Save to Research Library'
safariRef=add('safariSource','PBXFileReference',lastKnownFileType='sourcecode.swift',path='Apple/SafariExtension/SafariWebExtensionHandler.swift',sourceTree='<group>');sources.append(safariRef)
safariBuild=add('safariBuild','PBXBuildFile',fileRef=safariRef)
safariSrc=add('safariSources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[safariBuild],runOnlyForDeploymentPostprocessing=0)
safariResources=[]
for file in sorted((root/'Apple/SafariExtension/Resources').iterdir()):
 if not file.is_file(): continue
 ref=add('safariResource'+file.name,'PBXFileReference',path=str(file.relative_to(root)),sourceTree='<group>',lastKnownFileType='text' if file.suffix!='.svg' else 'image.svg');sources.append(ref)
 safariResources.append(add('safariResourceBuild'+file.name,'PBXBuildFile',fileRef=ref))
safariResourcePhase=add('safariResources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=safariResources,runOnlyForDeploymentPostprocessing=0)
safariFrameworks=add('safariFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)
safariProduct=add('safariProduct','PBXFileReference',explicitFileType='wrapper.app-extension',path=safariName+'.appex',sourceTree='BUILT_PRODUCTS_DIR');products.append(safariProduct)
safariPlist={'CFBundleName':safariName,'CFBundleDisplayName':safariName,'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundlePackageType':'XPC!','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','CFBundleDevelopmentRegion':'en','NSExtension':{'NSExtensionPointIdentifier':'com.apple.Safari.web-extension','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler'}}
(root/'Apple/SafariExtension/Info.plist').write_bytes(plistlib.dumps(safariPlist))
(root/'Apple/SafariExtension/Safari.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
safariConfigs=[]
for mode in ['Debug','Release']:
 safariConfigs.append(add('safari'+mode,'XCBuildConfiguration',name=mode,buildSettings={'PRODUCT_NAME':safariName,'PRODUCT_BUNDLE_IDENTIFIER':'org.researchlibrary.mac.safari','PRODUCT_MODULE_NAME':'ResearchLibrarySafari','INFOPLIST_FILE':'Apple/SafariExtension/Info.plist','SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0','SWIFT_VERSION':'5.0','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_ENTITLEMENTS':'Apple/SafariExtension/Safari.entitlements','APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks','@executable_path/../../../../Frameworks'],'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O'}))
safariCL=add('safariConfigs','XCConfigurationList',buildConfigurations=safariConfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
safariTarget=add('safariTarget','PBXNativeTarget',name=safariName,productName=safariName,productReference=safariProduct,productType='com.apple.product-type.app-extension',buildConfigurationList=safariCL,buildPhases=[safariSrc,safariFrameworks,safariResourcePhase],buildRules=[],dependencies=[]);targets.append(safariTarget)
safariProxy=add('safariProxy','PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=safariTarget,remoteInfo=safariName)
safariDependency=add('safariDependency','PBXTargetDependency',target=safariTarget,targetProxy=safariProxy)
safariEmbedFile=add('embedSafariFile','PBXBuildFile',fileRef=safariProduct,settings={'ATTRIBUTES':['RemoveHeadersOnCopy','CodeSignOnCopy']})
safariEmbed=add('embedSafari','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[safariEmbedFile],name='Embed Safari Extension',runOnlyForDeploymentPostprocessing=0)
objects[targets[0]]['dependencies'].append(safariDependency);objects[targets[0]]['buildPhases'].append(safariEmbed)
# Embed the capture Share Extension, with an explicit dependency.
proxy=add('shareProxy','PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=targets[2],remoteInfo='Research Library Share')
dep=add('shareDependency','PBXTargetDependency',target=targets[2],targetProxy=proxy)
embedFile=add('embedShareFile','PBXBuildFile',fileRef=products[2],settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
embed=add('embedShare','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embedFile],name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0)
objects[targets[1]]['dependencies']=[dep];objects[targets[1]]['buildPhases'].append(embed)
# Native simulator UI test bundle exercises the real queue and bookmark persistence.
testName='Research Library Capture UI Tests'
testRef=add('uiTestSource','PBXFileReference',lastKnownFileType='sourcecode.swift',path='Apple/UITests/CaptureUITests.swift',sourceTree='<group>');sources.append(testRef)
testBuild=add('uiTestBuild','PBXBuildFile',fileRef=testRef)
testSrc=add('uiTestSources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[testBuild],runOnlyForDeploymentPostprocessing=0)
testProduct=add('uiTestProduct','PBXFileReference',explicitFileType='wrapper.cfbundle',path=testName+'.xctest',sourceTree='BUILT_PRODUCTS_DIR');products.append(testProduct)
testConfigs=[]
for mode in ['Debug','Release']:
 testConfigs.append(add('uiTest'+mode,'XCBuildConfiguration',name=mode,buildSettings={'PRODUCT_NAME':testName,'PRODUCT_BUNDLE_IDENTIFIER':'org.researchlibrary.capture.uitests','GENERATE_INFOPLIST_FILE':'YES','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CODE_SIGN_STYLE':'Automatic','IPHONEOS_DEPLOYMENT_TARGET':'17.0','TARGETED_DEVICE_FAMILY':'1,2','TEST_TARGET_NAME':'Research Library Capture','ONLY_ACTIVE_ARCH':'YES'}))
testCL=add('uiTestConfigs','XCConfigurationList',buildConfigurations=testConfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')
testProxy=add('captureTestProxy','PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=targets[1],remoteInfo='Research Library Capture')
testDep=add('captureTestDependency','PBXTargetDependency',target=targets[1],targetProxy=testProxy)
testTarget=add('uiTestTarget','PBXNativeTarget',name=testName,productName=testName,productReference=testProduct,productType='com.apple.product-type.bundle.ui-testing',buildConfigurationList=testCL,buildPhases=[testSrc],buildRules=[],dependencies=[testDep]);targets.append(testTarget)
pg=add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
main=add('main','PBXGroup',children=sources+[pg],sourceTree='<group>')
pc=[]
for mode in ['Debug','Release']:pc.append(add('project'+mode,'XCBuildConfiguration',name=mode,buildSettings={'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','SDKROOT':'macosx'}))
cl=add('projectconfigs','XCConfigurationList',buildConfigurations=pc,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
project=add('project','PBXProject',attributes={'LastUpgradeCheck':'1600','TargetAttributes':{t:{'CreatedOnToolsVersion':'16.0'} for t in targets}},buildConfigurationList=cl,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=main,productRefGroup=pg,projectDirPath='',projectRoot='',targets=targets,packageReferences=[package])
objects[project]['attributes']['TargetAttributes'][testTarget]['TestTargetID']=targets[1]
path=root/'ResearchLibrary.xcodeproj';path.mkdir(exist_ok=True)
(path/'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project}))
# Shared schemes permit unsigned simulator and macOS CI builds.
for name,target in zip(['Research Library','Research Library Capture','Research Library Share'],targets):
 testAction = f'<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{testTarget}" BuildableName="{testName}.xctest" BlueprintName="{testName}" ReferencedContainer="container:ResearchLibrary.xcodeproj"/></TestableReference></Testables><MacroExpansion><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets[1]}" BuildableName="Research Library Capture.app" BlueprintName="Research Library Capture" ReferencedContainer="container:ResearchLibrary.xcodeproj"/></MacroExpansion></TestAction>' if name=='Research Library Capture' else ''
 scheme=f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.{'appex' if name.endswith('Share') else 'app'}" BlueprintName="{name}" ReferencedContainer="container:ResearchLibrary.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>{testAction}<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:ResearchLibrary.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>'''
 schemes=path/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True);(schemes/(name+'.xcscheme')).write_text(scheme)
print(path)
