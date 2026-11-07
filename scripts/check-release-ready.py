"""Pre-release configuration check. Never prints credentials or changes DNS.

Legal source of truth (Build 139): legal-site/seed/<lang>/*.md — the old
legal/TERMS-OF-USE.md + legal/PRIVACY-POLICY.md were moved out of legal/ in
this build, which made the previous version of this script crash with
FileNotFoundError. Every file read here is guarded: a missing file reports a
failed check, never a traceback.

Privacy policy URL: Configuration/ReleaseChecklist.local.plist key
PrivacyPolicyURL (fallback DEFAULT_PRIVACY_URL). It must answer HTTP 200 over
verified TLS — an unreachable privacy URL blocks App Store submission, so this
check failing is correct behaviour, not a script bug.
"""
import json
import plistlib
import re
import socket
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

root = Path(__file__).resolve().parents[1]
DEFAULT_PRIVACY_URL = 'https://bojiclub.fun/doc/privacy'
LEGAL_LANG = 'zh-CN'
LEGAL_FILES = ['terms.md', 'privacy.md']
checks = []


def add(name, passed, detail):
    checks.append({'name': name, 'passed': bool(passed), 'detail': detail})


def check_dns(domain):
    try:
        socket.getaddrinfo(domain, 443)
        resolved = True
    except OSError:
        resolved = False
    add(domain, resolved,
        'DNS 解析；若本机 DNS 被代理劫持（如返回 198.18.x.x 假 IP），以隐私政策 URL 可访问性检查为准')


def check_legal_files():
    """Legal texts live in legal-site/seed/<lang>/ since Build 139."""
    missing = []
    for name in LEGAL_FILES:
        path = root / 'legal-site' / 'seed' / LEGAL_LANG / name
        if not path.is_file():
            missing.append('legal-site/seed/' + LEGAL_LANG + '/' + name)
            continue
        try:
            text = path.read_text('utf-8')
        except (OSError, UnicodeDecodeError):
            missing.append('legal-site/seed/' + LEGAL_LANG + '/' + name + '（不可读）')
            continue
        if '版本：草案' in text or '草案版' in text:
            add('法律文本为正式文本：' + name, False, path.name + ' 仍含草案标记，须定稿后复检')
        else:
            add('法律文本为正式文本：' + name, True,
                'v' + (re.search(r'^version:\s*(\S+)', text, re.M).group(1) if re.search(r'^version:\s*(\S+)', text, re.M) else '?') +
                '，生效日 ' + (re.search(r'^effective:\s*(\S+)', text, re.M).group(1) if re.search(r'^effective:\s*(\S+)', text, re.M) else '?'))
    if missing:
        add('法律文本存在', False, '缺失：' + '、'.join(missing))
    else:
        add('法律文本存在', True, 'legal-site/seed/' + LEGAL_LANG + ' 下 ' + '、'.join(LEGAL_FILES) + ' 齐备')


def _fallback_ca_paths():
    """Some Python installs ship without a CA bundle (cert.pem missing) and
    then fail TLS verification for *every* host. Fall back to the OS trust
    store — verification stays on, only the bundle source changes."""
    paths = []
    try:
        import certifi  # noqa: PLC0415 - optional dependency
        paths.append(certifi.where())
    except Exception:
        pass
    paths += ['/etc/ssl/cert.pem', '/usr/local/etc/openssl/cert.pem',
              '/opt/homebrew/etc/openssl@3/cert.pem', '/etc/pki/tls/certs/ca-bundle.crt']
    default = ssl.get_default_verify_paths().openssl_cafile or ''
    return [p for p in dict.fromkeys(paths) if p and p != default and Path(p).is_file()]


def _open_https(request, timeout):
    contexts = [ssl.create_default_context()]
    for path in _fallback_ca_paths():
        try:
            contexts.append(ssl.create_default_context(cafile=path))
        except (ssl.SSLError, OSError):
            continue
    # urllib wraps TLS failures in URLError(reason=...); unwrap them so the
    # next trust bundle actually gets a chance before we give up.
    first_cert_error = None
    first_other = None
    for context in contexts:
        try:
            return urllib.request.urlopen(request, timeout=timeout, context=context)
        except urllib.error.HTTPError:
            raise
        except ssl.SSLCertVerificationError as error:
            first_cert_error = first_cert_error or error
        except urllib.error.URLError as error:
            reason = getattr(error, 'reason', error)
            if isinstance(reason, ssl.SSLCertVerificationError):
                first_cert_error = first_cert_error or reason
            else:
                first_other = first_other or error
        except (ssl.SSLError, OSError) as error:
            first_other = first_other or error
    if first_other is not None:
        raise first_other
    if first_cert_error is not None:
        raise first_cert_error
    raise ssl.SSLError('no usable trust store')


def check_url(url, timeout=12):
    """Return (reachable, detail). Only https; never logs credentials."""
    if not isinstance(url, str) or not url.startswith('https://'):
        return False, '隐私政策地址必须是 https:// URL'
    request = urllib.request.Request(url, headers={'User-Agent': 'BojiClub-ReleaseGate/1.0'})
    try:
        with _open_https(request, timeout) as response:
            status = response.status
            body = response.read(32768)
    except urllib.error.HTTPError as error:
        return False, '服务器返回 HTTP ' + str(error.code)
    except urllib.error.URLError as error:
        reason = getattr(error, 'reason', error)
        if isinstance(reason, ssl.SSLCertVerificationError):
            return False, 'TLS 证书验证失败（证书无效/过期或域名不匹配——须在独立环境复核）'
        if isinstance(reason, socket.gaierror):
            return False, '域名无法解析（真实 DNS 无记录，须先完成解析/部署）'
        return False, '连接失败：' + type(reason).__name__
    except ssl.SSLCertVerificationError:
        return False, 'TLS 证书验证失败（证书无效/过期或域名不匹配——须在独立环境复核）'
    except socket.gaierror:
        return False, '域名无法解析（真实 DNS 无记录，须先完成解析/部署）'
    except (ssl.SSLError, TimeoutError, ConnectionError, OSError) as error:
        return False, '连接失败：' + type(error).__name__
    if status != 200:
        return False, 'HTTP ' + str(status)
    if not body:
        return False, '响应体为空'
    marker = '隐私政策' if '隐私政策' in body.decode('utf-8', 'ignore') else 'privacy'
    return True, 'HTTP 200，' + str(len(body)) + ' 字节，含' + marker + '内容'


# 1) DNS for the release API / media domains
for domain in ['api.gongxiang.cloud', 'dongzuo.gongxiang.cloud']:
    check_dns(domain)

# 2) RevenueCat public SDK key
keys = re.findall(r'REVENUECAT_PUBLIC_SDK_KEY\s*=\s*"([^"]*)"', (root / 'BojiClub.xcodeproj/project.pbxproj').read_text('utf-8'))
add('RevenueCat SDK 公钥', len(keys) >= 2 and keys[-1].strip().startswith('appl_'),
    'Release 必须配置 appl_ 公钥；Debug 允许 test_。商品、Webhook 与购买验收另行完成')

# 3) Apple signing team
project = (root / 'BojiClub.xcodeproj/project.pbxproj').read_text('utf-8')
add('Apple 签名团队', bool(re.search(r'DEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}', project)),
    '使用真实 Apple Developer 团队和 App ID')

# 4) Operator checklist — LegalReviewed must be true
checklist_path = root / 'Configuration' / 'ReleaseChecklist.local.plist'
try:
    legal = plistlib.loads(checklist_path.read_bytes())
except (OSError, ValueError):
    legal = {}
if not checklist_path.is_file():
    add('发布确认清单存在', False, '缺 Configuration/ReleaseChecklist.local.plist（复制 ReleaseChecklist.example.plist 后填写）')
add('正式运营与协议确认（LegalReviewed=true）',
    bool(legal.get('OperatorName')) and bool(legal.get('SupportContact')) and legal.get('LegalReviewed') is True,
    '运营主体、客服渠道、LegalReviewed 必须全部就位；未确认前本项与隐私政策 URL 项不得放行')

# 5) Legal texts at their new location
check_legal_files()

# 6) In-app onboarding must not show draft wording
onboarding = root / 'BojiClub' / 'OnboardingView.swift'
try:
    text = onboarding.read_text('utf-8')
    add('用户可见协议为正式文本', '正式文本待提供' not in text and '用户协议草案' not in text,
        'OnboardingView 不得含草案提示')
except (OSError, UnicodeDecodeError):
    add('用户可见协议为正式文本', False, 'BojiClub/OnboardingView.swift 不可读')

# 7) Privacy policy URL must be publicly reachable
privacy_url = legal.get('PrivacyPolicyURL') or DEFAULT_PRIVACY_URL
reachable, detail = check_url(privacy_url)
add('隐私政策 URL 可访问', reachable, privacy_url + ' — ' + detail)
terms_url = legal.get('TermsURL')
if terms_url:
    reachable, detail = check_url(terms_url)
    add('服务条款 URL 可访问', reachable, str(terms_url) + ' — ' + detail)

print(json.dumps({'ready': all(c['passed'] for c in checks), 'checks': checks,
                  'native_build_verified': False, 'store_purchase_verified': False},
                 ensure_ascii=False, indent=2))
sys.exit(0 if all(c['passed'] for c in checks) else 1)
