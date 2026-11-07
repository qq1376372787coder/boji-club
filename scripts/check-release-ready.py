"""Pre-release configuration check. Never prints credentials or changes DNS."""
import json,plistlib,re,socket,sys
if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
from pathlib import Path
root=Path(__file__).resolve().parents[1]
project=(root/'BojiClub.xcodeproj/project.pbxproj').read_text('utf-8')
checks=[]
def add(name,passed,detail):checks.append({'name':name,'passed':bool(passed),'detail':detail})
for domain in ['api.gongxiang.cloud','dongzuo.gongxiang.cloud']:
    try:socket.getaddrinfo(domain,443);resolved=True
    except OSError:resolved=False
    add(domain,resolved,'DNS 解析；仍需验收 HTTPS 和完整接口')
keys=re.findall(r'REVENUECAT_PUBLIC_SDK_KEY\s*=\s*"([^"]*)"',project)
add('RevenueCat SDK 公钥',len(keys)>=2 and keys[-1].strip().startswith('appl_'),'Release 必须配置 appl_ 公钥；Debug 允许 test_。商品、Webhook 与购买验收另行完成')
add('Apple 签名团队',bool(re.search(r'DEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}',project)),'使用真实 Apple Developer 团队和 App ID')
checklist=root/'Configuration/ReleaseChecklist.local.plist'
try:legal=plistlib.loads(checklist.read_bytes())
except (OSError,ValueError):legal={}
add('正式运营与协议确认',bool(legal.get('OperatorName')) and bool(legal.get('SupportContact')) and legal.get('LegalReviewed') is True,'补全真实运营主体、联系渠道并确认正式协议')
texts=[(root/'legal'/name).read_text('utf-8') for name in ['TERMS-OF-USE.md','PRIVACY-POLICY.md']]
onboarding=(root/'BojiClub/OnboardingView.swift').read_text('utf-8')
add('用户可见协议为正式文本',all('版本：草案' not in text for text in texts) and '正式文本待提供' not in onboarding and '用户协议草案' not in onboarding,'保留草案提示直至真实文本与审核完成')
print(json.dumps({'ready':all(c['passed'] for c in checks),'checks':checks,'native_build_verified':False,'store_purchase_verified':False},ensure_ascii=False,indent=2))
sys.exit(0 if all(c['passed'] for c in checks) else 1)
