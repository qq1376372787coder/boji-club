"""Run on the Mac AFTER enabling Push Notifications for this Apple App ID."""
import pathlib,plistlib,re,shutil
root=pathlib.Path(__file__).resolve().parents[1]
project=root/'BojiClub.xcodeproj/project.pbxproj'
source=project.read_text('utf-8')
assert 'com.bojiclub.app.dev' in source
matches=re.findall(r'CODE_SIGN_ENTITLEMENTS = "?([^;"\n]+)',source)
main=[value.strip() for value in matches if value.startswith('BojiClub/')]
assert main and len(set(main))==1,'Main app entitlements must be unambiguous'
entitlement=root/main[0]
ent=plistlib.loads(entitlement.read_bytes());ent['aps-environment']='$(BOJI_APNS_ENVIRONMENT)'
info=root/'BojiClub/Info.plist';properties=plistlib.loads(info.read_bytes());properties['BojiAPNSEnvironment']='$(BOJI_APNS_ENVIRONMENT)'
count=0
def update(match):
    global count
    settings,name=match.group(1),match.group(2)
    if 'CODE_SIGN_ENTITLEMENTS' not in settings:return match.group(0)
    count+=1
    env='development' if name=='Debug' else 'production'
    settings=re.sub(r'\s*BOJI_APNS_ENVIRONMENT\s*=\s*[^;]+;','',settings)
    settings+=' BOJI_APNS_ENVIRONMENT = '+env+'; '
    active=re.search(r'SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*([^;]+);',settings)
    if active:
        value=active.group(1).strip().strip('"')
        if 'BOJI_REMOTE_PUSH' not in value:value+=' BOJI_REMOTE_PUSH'
        settings=settings[:active.start()]+'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "'+value+'";'+settings[active.end():]
    else:settings+=' SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) BOJI_REMOTE_PUSH"; '
    return 'buildSettings = {'+settings+'}; name = '+name+';'
updated=re.sub(r'buildSettings = \{([^{}]*)\}; name = (Debug|Release|TestFlight);',update,source)
assert count==6,'Expected three configurations for main app and widget'
for path in [project,entitlement,info]:
    backup=path.with_name(path.name+'.before-remote-push')
    if not backup.exists():shutil.copyfile(path,backup)
project.write_text(updated,'utf-8');entitlement.write_bytes(plistlib.dumps(ent,sort_keys=False));info.write_bytes(plistlib.dumps(properties,sort_keys=False))
print('Remote push enabled for signing: Debug=development; Release/TestFlight=production. Rebuild and validate the provisioning profiles.')
