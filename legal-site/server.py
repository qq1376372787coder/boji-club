#!/usr/bin/env python3
"""BOJI CLUB 法律协议网站 · 单文件服务（纯 Python 标准库，无第三方依赖）。

功能：
- 公开站点：协议列表页 + 协议正文页（9 种语言、深浅色、移动端适配、打印视图）
- 管理后台：/admin（密码登录、在线编辑协议、站点设置、导出/导入备份）
- 数据存储：data/content.json + data/config.json（原子写入 + 自动备份）

启动：python3 server.py [--port 8765]
环境变量：PORT、HOST、BOJI_ADMIN_PASSWORD（首次启动设置管理员密码）、BOJI_LEGAL_DATA
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import html as html_mod
import json
import os
import re
import secrets
import signal
import sys
import threading
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE = Path(__file__).resolve().parent
DATA_DIR = Path(os.environ.get("BOJI_LEGAL_DATA", BASE / "data"))
SEED_DIR = BASE / "seed"
ASSETS_DIR = BASE / "assets"
CONTENT_FILE = DATA_DIR / "content.json"
CONFIG_FILE = DATA_DIR / "config.json"
AUTH_FILE = DATA_DIR / "auth.json"
SESSIONS_FILE = DATA_DIR / "sessions.json"
BACKUP_DIR = DATA_DIR / "backups"

LOCK = threading.RLock()

DOC_ORDER = ["terms", "privacy", "purchase", "deletion", "ai-notice", "health-disclaimer", "about"]
PAGE_ORDER = ["faq", "changelog"]
ALL_CONTENT_IDS = DOC_ORDER + PAGE_ORDER

# 线条 SVG 图标（Lucide 风格，随主题着色），不用 emoji
_ICON_W = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
DOC_ICONS = {
    "terms": _ICON_W + '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M16 13H8"/><path d="M16 17H8"/><path d="M10 9H8"/></svg>',
    "privacy": _ICON_W + '<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/><circle cx="12" cy="16.5" r="1.4"/></svg>',
    "purchase": _ICON_W + '<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M2 10h20"/><path d="M6 15h4"/></svg>',
    "deletion": _ICON_W + '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="M10 11v6"/><path d="M14 11v6"/></svg>',
    "ai-notice": _ICON_W + '<path d="M12 3l1.9 5.7a2 2 0 0 0 1.4 1.4L21 12l-5.7 1.9a2 2 0 0 0-1.4 1.4L12 21l-1.9-5.7a2 2 0 0 0-1.4-1.4L3 12l5.7-1.9a2 2 0 0 0 1.4-1.4z"/></svg>',
    "health-disclaimer": _ICON_W + '<path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
    "about": _ICON_W + '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/></svg>',
    "faq": _ICON_W + '<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><path d="M12 17h.01"/></svg>',
    "changelog": _ICON_W + '<path d="M3 3v5h5"/><path d="M3.05 13A9 9 0 1 0 6 5.3L3 8"/><path d="M12 7v5l4 2"/></svg>',
}

_ICON_SUN = '<svg class="t-ico t-light" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="M4.9 4.9l1.4 1.4"/><path d="M17.7 17.7l1.4 1.4"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="M4.9 19.1l1.4-1.4"/><path d="M17.7 6.3l1.4-1.4"/></svg>'
_ICON_MOON = '<svg class="t-ico t-dark" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>'
_ICON_AUTO = '<svg class="t-ico t-auto" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8"/><path d="M12 17v4"/></svg>'
_ICON_PRINT = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9V3h12v6"/><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/><rect x="6" y="14" width="12" height="8"/></svg>'

LANGS = ["zh-CN", "zh-TW", "en", "ja", "ko", "th", "vi", "id", "ms"]
LANG_NATIVE = {
    "zh-CN": "简体中文", "zh-TW": "繁體中文", "en": "English", "ja": "日本語",
    "ko": "한국어", "th": "ไทย", "vi": "Tiếng Việt", "id": "Bahasa Indonesia", "ms": "Bahasa Melayu",
}
LANG_ALIASES = {
    "zh": "zh-CN", "zh-hans": "zh-CN", "zh-cn": "zh-CN", "zh_cn": "zh-CN", "zh-sg": "zh-CN",
    "zh-hant": "zh-TW", "zh-tw": "zh-TW", "zh_tw": "zh-TW", "zh-hk": "zh-TW", "zh-mo": "zh-TW",
    "en-us": "en", "en-gb": "en", "jp": "ja", "kr": "ko", "in": "id", "pt-br": "en",
    "yue": "zh-TW", "nan": "zh-TW",
}

SITE_NAME_DEFAULTS = {
    "zh-CN": "薄肌俱乐部（BOJI CLUB）",
    "zh-TW": "薄肌俱樂部（BOJI CLUB）",
    "*": "BOJI CLUB",
}

DEFAULT_CONFIG = {
    "site_names": {"zh-CN": SITE_NAME_DEFAULTS["zh-CN"], "zh-TW": SITE_NAME_DEFAULTS["zh-TW"], "*": SITE_NAME_DEFAULTS["*"]},
    # The operator explicitly authorized publishing the existing site identity
    # and support email. No personal phone number is published.
    "operator_name": "李佳艺",
    "contact_email": "biccyy@yeah.net",
    "domain": "https://bojiclub.fun",
    "storage_location": {"zh-CN": "中华人民共和国境内", "*": "mainland China (PRC)"},
    "icp_number": "",
    "app_store_url": "",
    "announcement": {"zh-CN": "", "*": ""},
}

_APPLE_LOGO_PATH = "M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z"
APPSTORE_BADGE = (
    '<svg class="as-badge" viewBox="0 0 135 40" role="img" aria-label="Download on the App Store">'
    '<rect x="0.5" y="0.5" width="134" height="39" rx="7" fill="currentColor"/>'
    f'<g transform="translate(11.5,8.5) scale(0.0455)"><path d="{_APPLE_LOGO_PATH}" fill="var(--as-logo,#f5f5f7)"/></g>'
    '<text x="34" y="15.5" fill="var(--as-logo,#f5f5f7)" font-size="8.5" font-family="-apple-system,\'SF Pro Text\',\'Helvetica Neue\',Arial,sans-serif">Download on the</text>'
    '<text x="33" y="30.5" fill="var(--as-logo,#f5f5f7)" font-size="15.5" font-weight="600" font-family="-apple-system,\'SF Pro Text\',\'Helvetica Neue\',Arial,sans-serif">App Store</text>'
    "</svg>"
)

UI = {
    "zh-CN": dict(home_sub="法律协议与隐私政策中心", docs_title="协议文件", updated="最后更新", effective="生效日期",
                  version="版本", toc="目录", back="返回首页", print="打印 / 导出 PDF", lang_label="语言",
                  theme_auto="跟随系统", theme_light="浅色", theme_dark="深色", contact="联系我们",
                  rights="保留所有权利", powered="本网站由{site}运营，用于公示产品相关协议与政策。",
                  admin="管理", not_found_title="页面不存在", not_found_body="你访问的页面不存在或已被移动。"),
    "zh-TW": dict(home_sub="法律協議與隱私權政策中心", docs_title="協議文件", updated="最後更新", effective="生效日期",
                  version="版本", toc="目錄", back="返回首頁", print="列印 / 匯出 PDF", lang_label="語言",
                  theme_auto="跟隨系統", theme_light="淺色", theme_dark="深色", contact="聯絡我們",
                  rights="保留所有權利", powered="本網站由{site}營運，用於公示產品相關協議與政策。",
                  admin="管理", not_found_title="頁面不存在", not_found_body="你存取的頁面不存在或已被移動。"),
    "en": dict(home_sub="Legal Agreements & Privacy Center", docs_title="Documents", updated="Last updated",
               effective="Effective date", version="Version", toc="On this page", back="Back to home",
               print="Print / PDF", lang_label="Language", theme_auto="System", theme_light="Light",
               theme_dark="Dark", contact="Contact us", rights="All rights reserved.",
               powered="This website is operated by {site} to publish the product's agreements and policies.",
               admin="Admin", not_found_title="Page not found", not_found_body="The page you requested does not exist or has been moved."),
    "ja": dict(home_sub="法的文書・プライバシーセンター", docs_title="文書一覧", updated="最終更新日", effective="発効日",
               version="バージョン", toc="目次", back="ホームに戻る", print="印刷 / PDF", lang_label="言語",
               theme_auto="システム", theme_light="ライト", theme_dark="ダーク", contact="お問い合わせ",
               rights="All rights reserved.", powered="本サイトは{site}が運営し、製品の規約・ポリシーを公開しています。",
               admin="管理", not_found_title="ページが見つかりません", not_found_body="お探しのページは存在しないか、移動しました。"),
    "ko": dict(home_sub="법적 문서 및 개인정보 센터", docs_title="문서 목록", updated="최종 업데이트", effective="시행일",
               version="버전", toc="목차", back="홈으로", print="인쇄 / PDF", lang_label="언어",
               theme_auto="시스템", theme_light="라이트", theme_dark="다크", contact="문의하기",
               rights="All rights reserved.", powered="본 웹사이트는 {site}이(가) 운영하며 제품 관련 약관과 정책을 게시합니다.",
               admin="관리", not_found_title="페이지를 찾을 수 없음", not_found_body="요청하신 페이지가 없거나 이동되었습니다."),
    "th": dict(home_sub="ศูนย์ข้อกำหนดและความเป็นส่วนตัว", docs_title="เอกสาร", updated="อัปเดตล่าสุด",
               effective="วันที่มีผลบังคับใช้", version="รุ่น", toc="สารบัญ", back="กลับหน้าหลัก",
               print="พิมพ์ / PDF", lang_label="ภาษา", theme_auto="ตามระบบ", theme_light="สว่าง",
               theme_dark="มืด", contact="ติดต่อเรา", rights="สงวนลิขสิทธิ์",
               powered="เว็บไซต์นี้ดำเนินการโดย {site} เพื่อเผยแพร่ข้อกำหนดและนโยบายของผลิตภัณฑ์",
               admin="ผู้ดูแล", not_found_title="ไม่พบหน้านี้", not_found_body="หน้าที่คุณขอไม่มีอยู่หรือถูกย้ายแล้ว"),
    "vi": dict(home_sub="Trung tâm điều khoản & quyền riêng tư", docs_title="Tài liệu", updated="Cập nhật lần cuối",
               effective="Ngày hiệu lực", version="Phiên bản", toc="Mục lục", back="Về trang chủ",
               print="In / PDF", lang_label="Ngôn ngữ", theme_auto="Theo hệ thống", theme_light="Sáng",
               theme_dark="Tối", contact="Liên hệ", rights="Bảo lưu mọi quyền.",
               powered="Trang web này do {site} vận hành để công bố các điều khoản và chính sách của sản phẩm.",
               admin="Quản trị", not_found_title="Không tìm thấy trang", not_found_body="Trang bạn yêu cầu không tồn tại hoặc đã bị di chuyển."),
    "id": dict(home_sub="Pusat Ketentuan & Privasi Hukum", docs_title="Dokumen", updated="Terakhir diperbarui",
               effective="Tanggal berlaku", version="Versi", toc="Daftar isi", back="Kembali ke beranda",
               print="Cetak / PDF", lang_label="Bahasa", theme_auto="Sistem", theme_light="Terang",
               theme_dark="Gelap", contact="Hubungi kami", rights="Hak cipta dilindungi.",
               powered="Situs ini dioperasikan oleh {site} untuk mempublikasikan ketentuan dan kebijakan produk.",
               admin="Admin", not_found_title="Halaman tidak ditemukan", not_found_body="Halaman yang Anda minta tidak ada atau telah dipindahkan."),
    "ms": dict(home_sub="Pusat Perjanjian & Privasi", docs_title="Dokumen", updated="Dikemas kini terakhir",
               effective="Tarikh berkuat kuasa", version="Versi", toc="Isi kandungan", back="Kembali ke laman utama",
               print="Cetak / PDF", lang_label="Bahasa", theme_auto="Sistem", theme_light="Cerah",
               theme_dark="Gelap", contact="Hubungi kami", rights="Hak cipta terpelihara.",
               powered="Laman ini dikendalikan oleh {site} untuk menerbitkan perjanjian dan polisi produk.",
               admin="Pentadbir", not_found_title="Halaman tidak dijumpai", not_found_body="Halaman yang anda minta tidak wujud atau telah dipindahkan."),
}

ICP_LINE_TEMPLATES = {
    "zh-CN": "- **ICP 备案号：**{n}",
    "zh-TW": "- **ICP 備案號：**{n}",
    "*": "- **ICP Filing No.:** {n}",
}


# ---------------------------------------------------------------- data store

def _atomic_write(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp-{uuid.uuid4().hex[:8]}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(data)
    os.replace(tmp, path)


def _backup(path: Path) -> None:
    if not path.exists():
        return
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    stem = path.stem
    backup_path = BACKUP_DIR / f"{stem}-{stamp}.json"
    fd = os.open(backup_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(path.read_text(encoding="utf-8"))
    backups = sorted(BACKUP_DIR.glob(f"{stem}-*.json"))
    for old in backups[:-30]:
        old.unlink(missing_ok=True)


def _load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def _save_json(path: Path, obj) -> None:
    with LOCK:
        _backup(path)
        _atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=1))


def parse_front_matter(text: str):
    meta, body = {}, text
    if text.startswith("---"):
        parts = text.split("\n---", 2)
        if len(parts) >= 2:
            head = parts[0][3:].strip("\r\n")
            rest = parts[1]
            if rest.startswith("\n") or rest.startswith("\r"):
                rest = rest[1:]
            meta = {}
            for line in head.splitlines():
                if ":" in line:
                    k, _, v = line.partition(":")
                    meta[k.strip()] = v.strip()
            body = rest.lstrip("\r\n")
    return meta, body


def import_seed(force: bool = False) -> dict:
    """Import seed markdown files into the content store."""
    store = _load_json(CONTENT_FILE, None)
    if store is None:
        store = {"docs": {}}
    for doc_id in ALL_CONTENT_IDS:
        entry = store["docs"].setdefault(doc_id, {"langs": {}})
        for lang in LANGS:
            path = SEED_DIR / lang / f"{doc_id}.md"
            if not path.exists():
                continue
            existing = entry["langs"].get(lang)
            if existing and existing.get("edited") and not force:
                continue
            if existing and not force:
                continue
            meta, body = parse_front_matter(path.read_text(encoding="utf-8"))
            entry["langs"][lang] = {
                "title": meta.get("title", doc_id),
                "description": meta.get("description", ""),
                "version": meta.get("version", "1.0.0"),
                "effective": meta.get("effective", ""),
                "updated": meta.get("updated", ""),
                "body": body,
                "edited": False,
                "edited_at": None,
            }
    _save_json(CONTENT_FILE, store)
    return store


def get_store() -> dict:
    store = _load_json(CONTENT_FILE, None)
    if store is None:
        store = import_seed()
    return store


def get_config() -> dict:
    cfg = _load_json(CONFIG_FILE, None)
    if cfg is None:
        cfg = json.loads(json.dumps(DEFAULT_CONFIG))
        _save_json(CONFIG_FILE, cfg)
    # merge missing keys from defaults
    for k, v in DEFAULT_CONFIG.items():
        cfg.setdefault(k, json.loads(json.dumps(v)))
    return cfg


_HOME_CONTENT: dict[str, dict] = {}


def _subst_deep(value, lang: str, cfg: dict):
    if isinstance(value, str):
        return apply_placeholders(value, lang, cfg)
    if isinstance(value, list):
        return [_subst_deep(v, lang, cfg) for v in value]
    if isinstance(value, dict):
        return {k: _subst_deep(v, lang, cfg) for k, v in value.items()}
    return value


def home_content(lang: str) -> dict:
    """官网落地页文案：seed/{lang}/home.json，回退 zh-CN → en。"""
    if not _HOME_CONTENT:
        for l in LANGS:
            p = SEED_DIR / l / "home.json"
            if p.exists():
                try:
                    _HOME_CONTENT[l] = json.loads(p.read_text(encoding="utf-8"))
                except Exception:
                    pass
    data = _HOME_CONTENT.get(lang) or _HOME_CONTENT.get("zh-CN") or _HOME_CONTENT.get("en") or {}
    return _subst_deep(data, lang, get_config())


# ---------------------------------------------------------------- auth

def init_auth() -> dict:
    auth = _load_json(AUTH_FILE, None)
    if auth:
        return auth
    password = os.environ.get("BOJI_ADMIN_PASSWORD", "")
    generated = False
    if not password:
        alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"
        password = "".join(secrets.choice(alphabet) for _ in range(14))
        generated = True
    auth = make_auth_entry(password)
    auth["must_change"] = True
    _save_json(AUTH_FILE, auth)
    if generated:
        note = DATA_DIR / "ADMIN_INITIAL_PASSWORD.txt"
        _atomic_write(note, password + "\n")
        print(f"[auth] 初始管理员密码已生成，见 {note}（登录后请立即修改并删除该文件）", flush=True)
    return auth


def make_auth_entry(password: str) -> dict:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000)
    return {"salt": salt, "hash": digest.hex(), "iterations": 200_000, "must_change": False}


def verify_password(auth: dict, password: str) -> bool:
    try:
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(auth["salt"]), int(auth.get("iterations", 200_000)))
        return hmac.compare_digest(digest.hex(), auth["hash"])
    except Exception:
        return False


def load_sessions() -> dict:
    return _load_json(SESSIONS_FILE, {})


def save_sessions(s: dict) -> None:
    _atomic_write(SESSIONS_FILE, json.dumps(s, ensure_ascii=False))


LOGIN_ATTEMPTS: dict[str, list[float]] = {}


def login_rate_limited(ip: str) -> bool:
    now = time.time()
    window = 600
    attempts = [t for t in LOGIN_ATTEMPTS.get(ip, []) if now - t < window]
    LOGIN_ATTEMPTS[ip] = attempts
    return len(attempts) >= 6


def record_login_failure(ip: str) -> None:
    LOGIN_ATTEMPTS.setdefault(ip, []).append(time.time())


# ---------------------------------------------------------------- markdown

_TAG_RE = re.compile(r"<[^>]+>")


def _inline(text: str) -> str:
    text = html_mod.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    def safe_markdown_link(match: re.Match) -> str:
        label, href = match.group(1), match.group(2)
        parsed = urllib.parse.urlsplit(href)
        if parsed.scheme.lower() not in ("https", "http", "mailto"):
            return label
        if parsed.scheme.lower() in ("http", "https") and not parsed.netloc:
            return label
        return (f'<a href="{html_mod.escape(href, quote=True)}" target="_blank" '
                f'rel="noopener noreferrer">{label}</a>')

    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", safe_markdown_link, text)
    return text


def _is_cjk(ch: str) -> bool:
    return "\u4e00" <= ch <= "\u9fff" or "\u3040" <= ch <= "\u30ff" or "\xac00" <= ch <= "\ud7af"


def _join(a: str, b: str) -> str:
    if not a or not b:
        return a + b
    return a + b if (_is_cjk(a[-1]) or _is_cjk(b[0])) else a + " " + b


def render_markdown(text: str, id_prefix: str = "sec"):
    """Render a markdown subset to HTML. Returns (html, toc list, heading_count)."""
    lines = text.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    toc: list[dict] = []
    para: list[str] = []
    i = 0
    h = 0

    def flush_para():
        nonlocal para
        if para:
            joined = ""
            for p in para:
                joined = _join(joined, p)
            out.append(f"<p>{_inline(joined)}</p>")
            para = []

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            flush_para()
            i += 1
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            flush_para()
            level = len(m.group(1)) + 1  # ## -> h3 ; # -> h2
            content = m.group(2).strip()
            h += 1
            hid = f"{id_prefix}-{h}"
            text_inline = _inline(content)
            out.append(f'<h{level} id="{hid}">{text_inline}</h{level}>')
            if level <= 3:
                toc.append({"level": level, "text": re.sub(r"<[^>]+>", "", text_inline), "id": hid})
            i += 1
            continue
        if stripped in ("---", "***", "___"):
            flush_para()
            out.append("<hr />")
            i += 1
            continue
        if stripped.startswith(">"):
            flush_para()
            quote: list[str] = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip().lstrip(">").strip())
                i += 1
            joined = ""
            for q in quote:
                joined = _join(joined, q)
            out.append(f"<blockquote>{_inline(joined)}</blockquote>")
            continue
        if stripped.startswith("|") and i + 1 < len(lines) and re.match(r"^\|?[\s:|-]+\|?\s*$", lines[i + 1].strip()) and "-" in lines[i + 1]:
            flush_para()
            rows: list[list[str]] = []
            header = [c.strip() for c in stripped.strip("|").split("|")]
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            t = ['<div class="table-wrap"><table>', "<thead><tr>"]
            t += [f"<th>{_inline(c)}</th>" for c in header]
            t.append("</tr></thead><tbody>")
            for row in rows:
                t.append("<tr>" + "".join(f"<td>{_inline(c)}</td>" for c in row) + "</tr>")
            t.append("</tbody></table></div>")
            out.append("".join(t))
            continue
        m = re.match(r"^[-*]\s+(.*)$", stripped)
        if m:
            flush_para()
            items: list[str] = []
            while i < len(lines):
                s = lines[i].strip()
                mm = re.match(r"^[-*]\s+(.*)$", s)
                if mm:
                    items.append(mm.group(1))
                    i += 1
                elif s and (lines[i].startswith("  ") or lines[i].startswith("\t")):
                    if items:
                        items[-1] = _join(items[-1], s.strip())
                    i += 1
                else:
                    break
            out.append("<ul>" + "".join(f"<li>{_inline(it)}</li>" for it in items) + "</ul>")
            continue
        m = re.match(r"^(\d+)[.、]\s*(.*)$", stripped)
        if m:
            flush_para()
            items = []
            while i < len(lines):
                s = lines[i].strip()
                mm = re.match(r"^(\d+)[.、]\s*(.*)$", s)
                if mm:
                    items.append((mm.group(1), mm.group(2)))
                    i += 1
                elif s and (lines[i].startswith("  ") or lines[i].startswith("\t")):
                    if items:
                        items[-1] = (items[-1][0], _join(items[-1][1], s.strip()))
                    i += 1
                else:
                    break
            out.append("<ol>" + "".join(f'<li value="{n}">{_inline(c)}</li>' for n, c in items) + "</ol>")
            continue
        if stripped.startswith("```"):
            flush_para()
            code: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            out.append("<pre><code>" + html_mod.escape("\n".join(code)) + "</code></pre>")
            continue
        para.append(stripped)
        i += 1
    flush_para()
    return "\n".join(out), toc, h


def heading_count(text: str) -> int:
    return len(re.findall(r"^##\s+", text, flags=re.M))


# ---------------------------------------------------------------- placeholders

def _map_get(value, lang: str, default="") -> str:
    if isinstance(value, dict):
        return str(value.get(lang) or value.get("*") or default)
    return str(value or default)


def site_full_name(lang: str, cfg: dict | None = None) -> str:
    cfg = cfg or get_config()
    return _map_get(cfg.get("site_names"), lang) or _map_get(SITE_NAME_DEFAULTS, lang)


def site_short_name(lang: str, cfg: dict | None = None) -> str:
    """页头短名：去掉括号内的英文名，避免小屏幕截断（如“薄肌俱乐部（BOJI CLUB）”→“薄肌俱乐部”）。"""
    full = site_full_name(lang, cfg)
    short = re.sub(r"[（(][^（()）]*[)）]\s*$", "", full).strip()
    return short or full


def apply_placeholders(text: str, lang: str, cfg: dict) -> str:
    site_name = _map_get(cfg.get("site_names"), lang) or _map_get(SITE_NAME_DEFAULTS, lang)
    storage = _map_get(cfg.get("storage_location"), lang)
    icp = str(cfg.get("icp_number") or "").strip()
    tpl = ICP_LINE_TEMPLATES.get(lang, ICP_LINE_TEMPLATES["*"])
    icp_line = tpl.format(n=icp) if icp else ""
    repl = {
        "{{site_name}}": site_name,
        "{{site_name_en}}": "BOJI CLUB",
        "{{operator_name}}": str(cfg.get("operator_name", "")),
        "{{contact_email}}": str(cfg.get("contact_email", "")),
        "{{domain}}": str(cfg.get("domain", "")),
        "{{storage_location}}": storage,
        "{{icp_line}}": icp_line,
    }
    for k, v in repl.items():
        text = text.replace(k, v)
    text = re.sub(r"^\s*-\s*$\n?", "", text, flags=re.M)  # drop emptied list items
    return text


# ---------------------------------------------------------------- lang helpers

def normalize_lang(raw: str | None) -> str | None:
    if not raw:
        return None
    key = raw.strip().lower()
    key = key.split(";")[0].split(",")[0]
    if key in LANGS:
        return key
    if key in LANG_ALIASES:
        return LANG_ALIASES[key]
    base = key.split("-")[0]
    if base in LANGS:
        return base
    if base in LANG_ALIASES:
        return LANG_ALIASES[base]
    return None


def detect_lang(handler: "Handler", cookie_lang: str | None) -> str:
    q = handler.query("lang") or handler.query("hl")
    lang = normalize_lang(q)
    if lang:
        return lang
    lang = normalize_lang(cookie_lang)
    if lang:
        return lang
    al = handler.headers.get("Accept-Language", "")
    for part in al.split(","):
        cand = normalize_lang(part.strip())
        if cand:
            return cand
    return "zh-CN"


def ui_strings(lang: str) -> dict:
    return UI.get(lang) or UI["en"]


# ---------------------------------------------------------------- pages

CSS = (ASSETS_DIR / "app.css").read_text(encoding="utf-8") if (ASSETS_DIR / "app.css").exists() else ""
JS = (ASSETS_DIR / "app.js").read_text(encoding="utf-8") if (ASSETS_DIR / "app.js").exists() else ""

THEME_INIT = """(function(){try{var p=new URLSearchParams(location.search);var t=p.get('theme');
if(t==='dark'||t==='light'){localStorage.setItem('boji-theme',t);}else{t=localStorage.getItem('boji-theme');}
if(!t){t='auto';}var d=document.documentElement;d.setAttribute('data-theme',t);
var l=p.get('lang')||p.get('hl');if(l){localStorage.setItem('boji-lang',l);}}catch(e){}})();"""


def asset_v(name: str) -> str:
    """Cache-busting version based on file mtime."""
    try:
        return str(int((ASSETS_DIR / name).stat().st_mtime))
    except Exception:
        return "1"


def page_shell(title: str, desc: str, lang: str, body: str, theme: str, noindex: bool = False,
               nav: list[tuple[str, str, bool]] | None = None, og_path: str = "/") -> str:
    u = ui_strings(lang)
    cfg = get_config()
    site = _map_get(cfg.get("site_names"), lang) or _map_get(SITE_NAME_DEFAULTS, lang)
    robots = '<meta name="robots" content="noindex, nofollow" />' if noindex else ""
    domain = str(cfg.get("domain", "")).rstrip("/")
    og = (f'<meta property="og:title" content="{html_mod.escape(title)} · {html_mod.escape(site)}" />'
          f'<meta property="og:description" content="{html_mod.escape(desc)}" />'
          '<meta property="og:type" content="website" />'
          f'<meta property="og:url" content="{html_mod.escape(domain + og_path, quote=True)}" />'
          f'<meta property="og:image" content="{html_mod.escape(domain + "/assets/apple-touch-icon.png", quote=True)}" />')
    theme_btn = (f'<button id="themeBtn" class="theme-btn" type="button" aria-label="theme" title="{html_mod.escape(u["theme_auto"])} / {html_mod.escape(u["theme_light"])} / {html_mod.escape(u["theme_dark"])}">'
                 f'{_ICON_AUTO}{_ICON_SUN}{_ICON_MOON}</button>')
    lang_opts = "".join(
        f'<option value="{l}"{" selected" if l == lang else ""}>{html_mod.escape(LANG_NATIVE[l])}</option>' for l in LANGS)
    lang_switch = (f'<label class="lang-select-wrap"><span class="visually-hidden">{html_mod.escape(u["lang_label"])}</span>'
                   f'<select id="langSelect" class="lang-select">{lang_opts}</select></label>')
    nav_html = ""
    if nav:
        links = "".join(f'<a class="topnav-link{" current" if cur else ""}" href="{html_mod.escape(href, quote=True)}">{html_mod.escape(label)}</a>'
                        for label, href, cur in nav)
        nav_html = f'<nav class="topnav" aria-label="main">{links}</nav>'
    page_links = "".join(
        f'<a href="/{p}?lang={urllib.parse.quote(lang)}">{html_mod.escape(_doc_title(p, lang))}</a>' for p in PAGE_ORDER)
    return f"""<!DOCTYPE html>
<html lang="{html_mod.escape(lang, quote=True)}" data-theme="{html_mod.escape(theme, quote=True)}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
<title>{html_mod.escape(title)} · {html_mod.escape(site)}</title>
<meta name="description" content="{html_mod.escape(desc)}" />
{robots}{og}
<link rel="icon" type="image/png" href="/assets/favicon.png" />
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png" />
<link rel="stylesheet" href="/assets/app.css?v={asset_v("app.css")}" />
<script>{THEME_INIT}</script>
<style>{CSS}</style>
</head>
<body>
<a class="skip-link" href="#main">Skip</a>
<header class="site-header">
  <div class="wrap header-inner">
    <a class="brand" href="/?lang={urllib.parse.quote(lang)}">
      <img class="brand-mark mark-light" src="/assets/BojiMark-light.svg" alt="" width="34" height="36" />
      <img class="brand-mark mark-dark" src="/assets/BojiMark-dark.svg" alt="" width="34" height="36" />
      <span class="brand-name">{html_mod.escape(site_short_name(lang))}</span>
    </a>
    {nav_html}
    <div class="header-controls">
      {lang_switch}
      {theme_btn}
    </div>
  </div>
</header>
<main id="main" class="wrap">
{body}
</main>
<footer class="site-footer">
  <div class="wrap footer-inner">
    <div class="footer-brand">
      <img class="brand-mark mark-light" src="/assets/BojiMark-light.svg" alt="" width="28" height="30" />
      <img class="brand-mark mark-dark" src="/assets/BojiMark-dark.svg" alt="" width="28" height="30" />
      <strong>{html_mod.escape(site)}</strong>
    </div>
    <p class="footer-note">{html_mod.escape(u["powered"]).replace("{site}", html_mod.escape(site))}</p>
    <p class="footer-links">{page_links}</p>
    <p class="footer-links">{' · '.join('<a href="/doc/%s?lang=%s">%s</a>' % (d, urllib.parse.quote(lang), html_mod.escape(_doc_title(d, lang))) for d in DOC_ORDER)}</p>
    <p class="footer-meta">{html_mod.escape(u["contact"])}: {html_mod.escape(str(cfg.get('contact_email','')))}<br/>
    © {datetime.now().year} {html_mod.escape(str(cfg.get('operator_name','')))} · {html_mod.escape(u["rights"])}</p>
  </div>
</footer>
<script>{JS}</script>
</body>
</html>"""


def _doc_title(doc_id: str, lang: str) -> str:
    store = get_store()
    entry = store["docs"].get(doc_id, {}).get("langs", {}).get(lang)
    if entry:
        return entry["title"]
    for fb in ("zh-CN", "en"):
        entry = store["docs"].get(doc_id, {}).get("langs", {}).get(fb)
        if entry:
            return entry["title"]
    return doc_id


def _top_nav(lang: str, current: str) -> list[tuple[str, str, bool]]:
    h = home_content(lang)
    return [
        (h.get("nav_features", "Features"), "/#features", current == "home"),
        (h.get("nav_faq", "FAQ"), f"/faq?lang={urllib.parse.quote(lang)}", current == "faq"),
        (h.get("nav_changelog", "Changelog"), f"/changelog?lang={urllib.parse.quote(lang)}", current == "changelog"),
        (h.get("nav_legal", "Legal"), f"/legal?lang={urllib.parse.quote(lang)}", current == "legal"),
    ]


def _legal_cards(lang: str) -> str:
    u = ui_strings(lang)
    store = get_store()
    cards = []
    for doc_id in DOC_ORDER:
        entry = store["docs"].get(doc_id, {}).get("langs", {}).get(lang) \
            or store["docs"].get(doc_id, {}).get("langs", {}).get("zh-CN") or {}
        title = entry.get("title", doc_id)
        desc = apply_placeholders(entry.get("description", ""), lang, get_config())
        cards.append(f"""<a class="doc-card" href="/doc/{doc_id}?lang={urllib.parse.quote(lang)}">
  <span class="doc-icon" aria-hidden="true">{DOC_ICONS.get(doc_id, "")}</span>
  <span class="doc-card-main">
    <span class="doc-card-title">{html_mod.escape(title)}</span>
    <span class="doc-card-desc">{html_mod.escape(desc)}</span>
    <span class="doc-card-meta">{html_mod.escape(u["version"])} {html_mod.escape(str(entry.get('version','')))} · {html_mod.escape(u["updated"])} {html_mod.escape(str(entry.get('updated','')))}</span>
  </span>
  <span class="doc-arrow" aria-hidden="true">›</span>
</a>""")
    return "".join(cards)


def render_landing(lang: str, theme: str) -> str:
    h = home_content(lang)
    cfg = get_config()
    site = site_full_name(lang)
    u = ui_strings(lang)
    store_url = str(cfg.get("app_store_url") or "#")
    badge = f'<a class="as-badge-link" href="{html_mod.escape(store_url, quote=True)}" target="_blank" rel="noopener noreferrer">{APPSTORE_BADGE}</a>'
    announce = _map_get(cfg.get("announcement"), lang)
    announce_bar = ""
    if announce:
        announce_bar = f'<div class="announce-bar"><span>{html_mod.escape(announce)}</span><button id="announceClose" type="button" aria-label="close">×</button></div>'
    features = "".join(
        f"""<div class="feature-card">
  <span class="feature-title">{html_mod.escape(f_.get("t",""))}</span>
  <span class="feature-desc">{html_mod.escape(f_.get("d",""))}</span>
</div>""" for f_ in h.get("features", []))
    shots = "".join(
        f"""<figure class="shot">
  <img src="/assets/screenshots/{html_mod.escape(s_.get('file',''), quote=True)}" alt="{html_mod.escape(s_.get('cap',''))}" loading="lazy" width="240" height="520" />
  <figcaption>{html_mod.escape(s_.get("cap",""))}</figcaption>
</figure>""" for s_ in h.get("shots", []))
    body = f"""{announce_bar}
<section class="hero hero-landing">
  <div class="hero-logo"><img class="brand-mark mark-light" src="/assets/BojiMark-light.svg" alt="" width="72" height="77" /><img class="brand-mark mark-dark" src="/assets/BojiMark-dark.svg" alt="" width="72" height="77" /></div>
  <p class="hero-badge">{html_mod.escape(h.get("hero_badge",""))}</p>
  <h1>{html_mod.escape(h.get("hero_title",""))}</h1>
  <p class="hero-sub">{html_mod.escape(h.get("hero_sub",""))}</p>
  <div class="hero-cta">{badge}<a class="btn-ghost" href="/legal?lang={urllib.parse.quote(lang)}">{html_mod.escape(h.get("nav_legal",""))}</a></div>
  <p class="download-note">{html_mod.escape(h.get("download_note",""))}</p>
</section>
<section class="home-section" id="features">
  <h2 class="section-title">{html_mod.escape(h.get("features_title",""))}</h2>
  <p class="section-sub">{html_mod.escape(h.get("features_sub",""))}</p>
  <div class="feature-grid">{features}</div>
</section>
<section class="home-section">
  <h2 class="section-title">{html_mod.escape(h.get("shots_title",""))}</h2>
  <p class="section-sub">{html_mod.escape(h.get("shots_sub",""))}</p>
  <div class="shots-strip">{shots}</div>
</section>
<section class="home-section cta-band">
  <h2 class="cta-title">{html_mod.escape(h.get("cta_title",""))}</h2>
  <p class="cta-sub">{html_mod.escape(h.get("cta_sub",""))}</p>
  <div class="hero-cta">{badge}</div>
  <p class="legal-hint">{html_mod.escape(h.get("legal_hint",""))}</p>
</section>"""
    return page_shell(site, h.get("hero_sub", ""), lang, body, theme,
                      nav=_top_nav(lang, "home"), og_path="/")


def render_legal_home(lang: str, theme: str) -> str:
    u = ui_strings(lang)
    site = site_full_name(lang)
    body = f"""
<section class="hero">
  <div class="hero-logo"><img class="brand-mark mark-light" src="/assets/BojiMark-light.svg" alt="" width="72" height="77" /><img class="brand-mark mark-dark" src="/assets/BojiMark-dark.svg" alt="" width="72" height="77" /></div>
  <h1>{html_mod.escape(site)}</h1>
  <p class="hero-sub">{html_mod.escape(u["home_sub"])}</p>
</section>
<section class="doc-list">
  <h2 class="section-title">{html_mod.escape(u["docs_title"])}</h2>
  <div class="doc-cards">{_legal_cards(lang)}</div>
</section>"""
    return page_shell(u["home_sub"], u["home_sub"], lang, body, theme, nav=_top_nav(lang, "legal"), og_path="/legal")


def render_doc(doc_id: str, lang: str, theme: str, print_view: bool = False) -> str | None:
    if doc_id not in ALL_CONTENT_IDS:
        return None
    u = ui_strings(lang)
    store = get_store()
    entry = store["docs"].get(doc_id, {}).get("langs", {}).get(lang) \
        or store["docs"].get(doc_id, {}).get("langs", {}).get("zh-CN")
    if not entry:
        return None
    cfg = get_config()
    body_md = apply_placeholders(entry.get("body", ""), lang, cfg)
    html_body, toc, _h = render_markdown(body_md, id_prefix=doc_id)
    title = entry.get("title", doc_id)
    desc = apply_placeholders(entry.get("description", ""), lang, cfg)
    chips = (f'<span class="chip">{html_mod.escape(u["version"])} {html_mod.escape(str(entry.get("version","")))}</span>'
             f'<span class="chip">{html_mod.escape(u["effective"])} {html_mod.escape(str(entry.get("effective","")))}</span>'
             f'<span class="chip">{html_mod.escape(u["updated"])} {html_mod.escape(str(entry.get("updated","")))}</span>')
    legal_links = "".join(
        f'<a class="toc-other{" current" if d == doc_id else ""}" href="/doc/{d}?lang={urllib.parse.quote(lang)}">{html_mod.escape(_doc_title(d, lang))}</a>'
        for d in DOC_ORDER)
    page_links = "".join(
        f'<a class="toc-other{" current" if p == doc_id else ""}" href="/{p}?lang={urllib.parse.quote(lang)}">{html_mod.escape(_doc_title(p, lang))}</a>'
        for p in PAGE_ORDER)
    toc_html = "".join(f'<a class="toc-l{t["level"]}" href="#{t["id"]}">{html_mod.escape(t["text"])}</a>' for t in toc)
    if print_view:
        body = f"""<article class="doc-article print-article">
<h1 class="doc-title">{html_mod.escape(title)}</h1>
<div class="doc-chips">{chips}</div>
<div class="doc-body">{html_body}</div>
</article>"""
        return page_shell(title, desc, lang, body, "light", noindex=True)
    back = f'<a class="back-link" href="/legal?lang={urllib.parse.quote(lang)}">{html_mod.escape(u["back"])}</a>'
    print_link = (f'<a class="print-link" href="/print/{doc_id}?lang={urllib.parse.quote(lang)}&theme=light" target="_blank" rel="noopener">'
                  f'{_ICON_PRINT}<span>{html_mod.escape(u["print"])}</span></a>')
    body = f"""{back}
<div class="doc-layout">
<aside class="doc-aside" id="docAside">
  <nav class="toc-nav" aria-label="{html_mod.escape(u["toc"])}">
    <p class="toc-title">{html_mod.escape(u["toc"])}</p>
    {toc_html}
    <p class="toc-title toc-title-other">{html_mod.escape(u["docs_title"])}</p>
    {legal_links}
    <p class="toc-title toc-title-other">{html_mod.escape(" / ".join(_doc_title(p, lang) for p in PAGE_ORDER))}</p>
    {page_links}
  </nav>
</aside>
<article class="doc-article{' faq-article' if doc_id == 'faq' else ''}" id="article">
  <div class="doc-head">
    <span class="doc-hero-icon" aria-hidden="true">{DOC_ICONS.get(doc_id, "")}</span>
    <h1 class="doc-title">{html_mod.escape(title)}</h1>
    <div class="doc-chips">{chips}</div>
  </div>
  <div class="doc-body" id="docBody">{html_body}</div>
  <div class="doc-foot-actions">{print_link}</div>
</article>
</div>"""
    return page_shell(title, desc, lang, body, theme, nav=_top_nav(lang, doc_id),
                      og_path=f"/doc/{doc_id}" if doc_id in DOC_ORDER else f"/{doc_id}")


def render_sitemap() -> str:
    cfg = get_config()
    domain = str(cfg.get("domain", "")).rstrip("/")
    today = datetime.now().strftime("%Y-%m-%d")
    paths = ["/", "/legal", "/faq", "/changelog"] + [f"/doc/{d}" for d in DOC_ORDER]
    urls = []
    for lang in LANGS:
        for p in paths:
            urls.append(f"<url><loc>{html_mod.escape(domain + p, quote=True)}?lang={lang}</loc><lastmod>{today}</lastmod></url>")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
            + "".join(urls) + "</urlset>")


def render_404(lang: str, theme: str) -> str:
    u = ui_strings(lang)
    body = f"""<div class="nf">
<h1>{html_mod.escape(u["not_found_title"])}</h1>
<p>{html_mod.escape(u["not_found_body"])}</p>
<p><a class="back-link" href="/?lang={urllib.parse.quote(lang)}">{html_mod.escape(u["back"])}</a></p>
</div>"""
    return page_shell(u["not_found_title"], "", lang, body, theme, noindex=True)


# ---------------------------------------------------------------- admin

ADMIN_HTML = """<!DOCTYPE html>
<html lang="zh-CN" data-theme="auto">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>管理后台 · BOJI CLUB</title>
<meta name="robots" content="noindex, nofollow" />
<link rel="icon" type="image/png" href="/assets/favicon.png" />
<style>
:root{--bg:#f5f6f8;--card:#fff;--text:#1c1e21;--muted:#667085;--line:#e4e7ec;--accent:#414d63;--accent-soft:#e3e7f0;--ok:#12805c;--warn:#b54708;--radius:14px;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
[data-theme=dark]{--bg:#16181c;--card:#1f2227;--text:#e8eaed;--muted:#9aa2af;--line:#303338;--accent:#b8cce6;--accent-soft:#232a35;--ok:#3ccb96;--warn:#f79009}
@media(prefers-color-scheme:dark){[data-theme=auto]{--bg:#16181c;--card:#1f2227;--text:#e8eaed;--muted:#9aa2af;--line:#303338;--accent:#b8cce6;--accent-soft:#232a35;--ok:#3ccb96;--warn:#f79009}}
*{box-sizing:border-box}body{margin:0;font-family:-apple-system,"SF Pro Text","PingFang SC","HarmonyOS Sans SC","MiSans","Noto Sans CJK SC","Microsoft YaHei",system-ui,sans-serif;background:var(--bg);color:var(--text);line-height:1.6}
.wrap{max-width:1080px;margin:0 auto;padding:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:22px;margin-bottom:18px}
h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:0 0 12px}
.sub{color:var(--muted);font-size:13px;margin:0 0 18px}
input,textarea,select{width:100%;padding:9px 12px;border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--text);font:inherit}
textarea.body{font-family:var(--mono);font-size:13px;line-height:1.7;min-height:380px;resize:vertical;white-space:pre;overflow-x:auto}
textarea.desc{min-height:64px;resize:vertical}
label{display:block;font-size:12px;color:var(--muted);margin:12px 0 5px}
button{border:0;border-radius:10px;padding:9px 16px;font:inherit;font-weight:600;cursor:pointer;background:var(--accent);color:#fff}
button.ghost{background:transparent;color:var(--accent);border:1px solid var(--accent)}
button.dim{background:var(--bg);color:var(--muted);border:1px solid var(--line)}
button:disabled{opacity:.5;cursor:default}
.row{display:flex;gap:12px;flex-wrap:wrap}.row>div{flex:1;min-width:150px}
.tabs{display:flex;gap:6px;margin-bottom:16px;flex-wrap:wrap}
.tabs button{background:var(--card);color:var(--muted);border:1px solid var(--line)}
.tabs button.on{background:var(--accent);color:#fff;border-color:var(--accent)}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:9px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:12px}
td.cell{cursor:pointer;border-radius:8px}td.cell:hover{background:var(--accent-soft)}
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--warn);margin-left:5px;vertical-align:middle}
.banner{background:var(--accent-soft);color:var(--accent);border-radius:10px;padding:10px 14px;font-size:13px;margin-bottom:14px}
.msg{padding:10px 14px;border-radius:10px;font-size:13px;margin:10px 0;display:none}
.msg.ok{display:block;background:rgba(18,128,92,.12);color:var(--ok)}
.msg.err{display:block;background:rgba(181,71,8,.12);color:var(--warn)}
.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:14px}
.login-card{max-width:380px;margin:12vh auto}
.hint{font-size:12px;color:var(--muted)}
.mono{font-family:var(--mono)}
.cellbtn{padding:4px 9px;font-size:12px;border-radius:8px}
</style>
</head>
<body>
<div class="wrap">
<div id="app"></div>
</div>
<script>
var LANGS=__LANGS__,LANGNATIVE=__LANGNATIVE__,DOCS=__DOCS__;
var app=document.getElementById('app'),csrf='';
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function api(path,opts){opts=opts||{};opts.headers=Object.assign({'Content-Type':'application/json','X-CSRF-Token':csrf},opts.headers||{});
 return fetch(path,opts).then(function(r){if(r.status===401){showLogin();throw new Error('unauthorized')}return r.json()})}
function msg(el,text,ok){el.className='msg '+(ok?'ok':'err');el.textContent=text}
/* ---------- login ---------- */
function showLogin(msgText){app.innerHTML='<div class="card login-card"><h1>BOJI CLUB 管理后台</h1><p class="sub">请输入管理员密码登录</p>'+
 (msgText?'<div class="msg err">'+esc(msgText)+'</div>':'')+
 '<label>管理员密码</label><input id="pw" type="password" autofocus />'+
 '<div class="actions"><button id="btnLogin">登录</button></div>'+
 '<p class="hint">首次部署的初始密码见服务器 data/ADMIN_INITIAL_PASSWORD.txt</p></div>';
 var pw=document.getElementById('pw');pw.focus();
 function go(){fetch('/api/admin/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:pw.value})})
  .then(function(r){return r.json().then(function(j){return {s:r.status,j:j}})})
  .then(function(o){if(o.s===200){loadHome()}else{showLogin(o.j&&o.j.error||'登录失败')}})
  .catch(function(){showLogin('网络错误')})}
 document.getElementById('btnLogin').onclick=go;pw.addEventListener('keydown',function(e){if(e.key==='Enter')go()})}
/* ---------- home ---------- */
var state={tab:'docs',doc:null,lang:null,dirty:false};
function loadHome(){api('/api/admin/session').then(function(s){csrf=s.csrf;
 if(s.must_change){/* banner rendered in tabs */}render()})}
function render(){
 api('/api/admin/list').then(function(list){renderTabs();renderBody(list)})}
function renderTabs(){var t=document.createElement('div');t.className='tabs';
 [['docs','协议文档'],['config','站点设置'],['security','账号安全']].forEach(function(p){
  var b=document.createElement('button');b.textContent=p[1];if(state.tab===p[0])b.className='on';
  b.onclick=function(){state.tab=p[0];render()};t.appendChild(b)});
 var out=document.createElement('button');out.textContent='退出登录';out.className='dim';out.style.marginLeft='auto';
 out.onclick=function(){api('/api/admin/logout',{method:'POST'}).then(function(){showLogin()})};t.appendChild(out);
 var head=document.createElement('div');head.innerHTML='<h1>BOJI CLUB · 协议管理</h1><p class="sub">编辑后点击“保存文档”即对线上生效。带 <span class="dot"></span> 的单元格表示已被手动编辑。</p>';
 app.innerHTML='';app.appendChild(head);app.appendChild(t)}
function renderBody(list){
 var c=document.createElement('div');c.className='card';
 if(state.tab==='docs'){
  function groupTable(title,docs){
   var h='<h2 style="margin-top:6px">'+esc(title)+'</h2><table><tr><th>ID</th>'+LANGS.map(function(l){return '<th>'+esc(LANGNATIVE[l])+'</th>'}).join('')+'</tr>';
   docs.forEach(function(d){
    h+='<tr><td style="white-space:nowrap">'+esc(d.id)+'</td>';
    LANGS.forEach(function(l){
     var cell=list.docs[d.id]&&list.docs[d.id][l];
     if(!cell){h+='<td class="hint">—</td>';return}
     h+='<td class="cell" data-doc="'+d.id+'" data-lang="'+l+'">'+esc(cell.title)+
      '<br><span class="hint">v'+esc(cell.version)+(cell.edited?'<span class="dot" title="已手动编辑"></span>':'')+'</span></td>'});
    h+='</tr>'});
   return h+'</table>'}
  c.innerHTML=groupTable('协议文档（App 内与 App Store 引用）',DOCS.filter(function(d){return d.group==='legal'}))+
   groupTable('网站页面（官网导航与页脚）',DOCS.filter(function(d){return d.group==='page'}))+
   '<p class="hint">提示：正文中可用占位符 '+esc('{{site_name}} {{operator_name}} {{contact_email}} {{domain}} {{storage_location}} {{icp_line}}')+'，保存后自动替换为站点设置中的最新值。</p>';
  c.querySelectorAll('td.cell').forEach(function(td){td.onclick=function(){openEditor(td.dataset.doc,td.dataset.lang)}});
  if(state.doc){c.appendChild(editorPanel())}
 } else if(state.tab==='config'){renderConfig(c)}
 else {renderSecurity(c)}
 app.appendChild(c)}
function editorPanel(){
 var meta=state.data;
 var p=document.createElement('div');p.className='card';
 p.innerHTML='<h2>编辑：'+esc(state.doc)+' · '+esc(LANGNATIVE[state.lang])+(meta.edited?'<span class="dot"></span>':'')+'</h2>'+
 '<div class="banner" id="edMsg" style="display:none"></div>'+
 '<div class="row"><div><label>标题</label><input id="mTitle" value="'+esc(meta.title)+'"/></div>'+
 '<div><label>版本</label><input id="mVersion" value="'+esc(meta.version)+'"/></div></div>'+
 '<div class="row"><div><label>生效日期</label><input id="mEffective" value="'+esc(meta.effective)+'" placeholder="YYYY-MM-DD"/></div>'+
 '<div><label>最后更新</label><input id="mUpdated" value="'+esc(meta.updated)+'" placeholder="YYYY-MM-DD"/></div></div>'+
 '<label>描述（首页卡片展示）</label><textarea id="mDesc" class="desc">'+esc(meta.description)+'</textarea>'+
 '<label>正文（Markdown）</label><textarea id="mBody" class="body">'+esc(meta.body)+'</textarea>'+
 '<div class="actions"><button id="btnSave">保存文档</button>'+
 '<a href="/print/'+esc(state.doc)+'?lang='+esc(state.lang)+'&theme=light" target="_blank"><button class="ghost" type="button">预览</button></a>'+
 '<button class="dim" id="btnRestore">恢复该语言默认内容</button>'+
 '<span class="hint" style="align-self:center" id="wordCount"></span></div>';
 var body=p.querySelector('#mBody');
 function wc(){p.querySelector('#wordCount').textContent=body.value.length+' 字符'}
 body.addEventListener('input',function(){wc();state.dirty=true});wc();
 p.querySelector('#btnSave').onclick=function(){
  api('/api/admin/save',{method:'POST',body:JSON.stringify({doc:state.doc,lang:state.lang,
   title:p.querySelector('#mTitle').value,version:p.querySelector('#mVersion').value,
   effective:p.querySelector('#mEffective').value,updated:p.querySelector('#mUpdated').value,
   description:p.querySelector('#mDesc').value,body:body.value})})
  .then(function(r){var m=p.querySelector('#edMsg');if(r.ok){m.style.display='block';msg(m,'已保存并生效',true);state.dirty=false;render()}else msg(m,r.error||'保存失败',false)})};
 p.querySelector('#btnRestore').onclick=function(){
  if(!confirm('确定恢复「'+state.doc+' / '+state.lang+'」为内置默认内容？当前编辑将丢失。'))return;
  api('/api/admin/restore',{method:'POST',body:JSON.stringify({doc:state.doc,lang:state.lang})})
  .then(function(r){var m=p.querySelector('#edMsg');if(r.ok){state.doc=null;render()}else msg(m,r.error||'失败',false)})};
 return p}
function openEditor(doc,lang){api('/api/admin/doc/'+encodeURIComponent(doc)+'/'+encodeURIComponent(lang))
 .then(function(d){state.doc=doc;state.lang=lang;state.data=d.doc;state.dirty=false;render()})}
/* ---------- config ---------- */
function renderConfig(c){api('/api/admin/config').then(function(cfg){
 c.innerHTML='<h2>站点与官网设置</h2><p class="hint">这些值会实时替换到所有语言的协议正文占位符与官网页面中。</p><div id="cfgMsg" class="msg"></div>'+
 '<div class="row"><div><label>运营者名称</label><input id="cOperator" value="'+esc(cfg.operator_name)+'"/></div>'+
 '<div><label>联系邮箱</label><input id="cEmail" value="'+esc(cfg.contact_email)+'"/></div>'+
 '<div></div></div>'+
 '<div class="row"><div><label>网站域名（含 https://）</label><input id="cDomain" value="'+esc(cfg.domain)+'"/></div>'+
 '<div><label>ICP 备案号（可留空）</label><input id="cIcp" value="'+esc(cfg.icp_number)+'"/></div></div>'+
 '<div class="row"><div><label>App Store 链接（官网下载按钮，如 https://apps.apple.com/app/idXXXXXXXXX，可留空）</label><input id="cStore" value="'+esc(cfg.app_store_url)+'"/></div></div>'+
 '<div class="row"><div><label>官网公告条（简中，留空则不显示）</label><input id="cAnnCn" value="'+esc(cfg.announcement['zh-CN']||'')+'"/></div>'+
 '<div><label>官网公告条（其他语言，留空则不显示）</label><input id="cAnnDef" value="'+esc(cfg.announcement['*']||'')+'"/></div></div>'+
 '<div class="row"><div><label>站点名称（简中）</label><input id="cSnCn" value="'+esc(cfg.site_names['zh-CN']||'')+'"/></div>'+
 '<div><label>站点名称（繁中）</label><input id="cSnTw" value="'+esc(cfg.site_names['zh-TW']||'')+'"/></div>'+
 '<div><label>站点名称（其他语言）</label><input id="cSnDef" value="'+esc(cfg.site_names['*']||'')+'"/></div></div>'+
 '<div class="row"><div><label>数据存储地（简中描述）</label><input id="cStCn" value="'+esc(cfg.storage_location['zh-CN']||'')+'"/></div>'+
 '<div><label>数据存储地（其他语言）</label><input id="cStDef" value="'+esc(cfg.storage_location['*']||'')+'"/></div></div>'+
 '<div class="actions"><button id="btnCfgSave">保存设置</button>'+
 '<button class="ghost" id="btnExport">导出全部内容备份</button>'+
 '<label class="hint" style="display:inline-flex;align-items:center;gap:6px;margin:0">导入备份 <input type="file" id="importFile" accept=".json" style="width:auto"/></label></div>';
 c.querySelector('#btnCfgSave').onclick=function(){
  api('/api/admin/config/save',{method:'POST',body:JSON.stringify({
   operator_name:c.querySelector('#cOperator').value,contact_email:c.querySelector('#cEmail').value,
   domain:c.querySelector('#cDomain').value,
   icp_number:c.querySelector('#cIcp').value,app_store_url:c.querySelector('#cStore').value,
   announcement:{'zh-CN':c.querySelector('#cAnnCn').value,'*':c.querySelector('#cAnnDef').value},
   site_names:{'zh-CN':c.querySelector('#cSnCn').value,'zh-TW':c.querySelector('#cSnTw').value,'*':c.querySelector('#cSnDef').value},
   storage_location:{'zh-CN':c.querySelector('#cStCn').value,'*':c.querySelector('#cStDef').value}})})
  .then(function(r){msg(c.querySelector('#cfgMsg'),r.ok?'已保存，所有语言正文中的占位符已同步更新':'保存失败',!!r.ok)})};
 c.querySelector('#btnExport').onclick=function(){location.href='/api/admin/export'};
 c.querySelector('#importFile').addEventListener('change',function(ev){
  var f=ev.target.files[0];if(!f)return;
  if(!confirm('导入将覆盖当前全部协议内容与站点设置，确定继续？'))return;
  var rd=new FileReader();rd.onload=function(){try{var j=JSON.parse(rd.result);
   api('/api/admin/import',{method:'POST',body:JSON.stringify(j)})
   .then(function(r){alert(r.ok?'导入成功':'导入失败：'+(r.error||''));render()})}catch(e){alert('文件不是有效 JSON')}};rd.readAsText(f)})})}
/* ---------- security ---------- */
function renderSecurity(c){api('/api/admin/session').then(function(s){
 c.innerHTML='<h2>账号安全</h2>'+(s.must_change?'<div class="banner">注意：你仍在使用初始密码，请立即修改。</div>':'')+
 '<div id="secMsg" class="msg"></div>'+
 '<div class="row"><div><label>当前密码</label><input id="sOld" type="password"/></div></div>'+
 '<div class="row"><div><label>新密码（至少 10 位）</label><input id="sNew" type="password"/></div>'+
 '<div><label>确认新密码</label><input id="sNew2" type="password"/></div></div>'+
 '<div class="actions"><button id="btnPw">修改密码</button></div>'+
 '<p class="hint">修改密码后需要重新登录。登录会话有效期 7 天。</p>';
 c.querySelector('#btnPw').onclick=function(){
  var a=c.querySelector('#sNew').value,b=c.querySelector('#sNew2').value,m=c.querySelector('#secMsg');
  if(a!==b){msg(m,'两次输入的新密码不一致',false);return}
  api('/api/admin/password',{method:'POST',body:JSON.stringify({old:c.querySelector('#sOld').value,new:a})})
  .then(function(r){if(r.ok){msg(m,'已修改，正在跳转登录…',true);setTimeout(function(){location.reload()},1200)}
   else msg(m,r.error||'修改失败',false)})}})}
showLogin();
</script>
</body>
</html>"""


# ---------------------------------------------------------------- http handler

class Handler(BaseHTTPRequestHandler):
    server_version = "BojiLegal/1.0"
    protocol_version = "HTTP/1.1"

    # ---- helpers
    def log_message(self, fmt, *args):
        sys.stdout.write("[%s] %s - %s\n" % (datetime.now().strftime("%H:%M:%S"), self.address_string(), fmt % args))

    def query(self, key: str) -> str | None:
        if not hasattr(self, "_query"):
            parsed = urllib.parse.urlparse(self.path)
            self._query = urllib.parse.parse_qs(parsed.query)
        vals = self._query.get(key)
        return vals[0] if vals else None

    def cookies(self) -> dict:
        out = {}
        raw = self.headers.get("Cookie", "")
        for part in raw.split(";"):
            if "=" in part:
                k, _, v = part.strip().partition("=")
                out[k] = v
        return out

    def is_https(self) -> bool:
        return self._trusted_proxy() and self.headers.get("X-Forwarded-Proto", "").lower() == "https"

    def public_site_ready(self) -> bool:
        cfg = get_config()
        operator = str(cfg.get("operator_name", "")).strip()
        email = str(cfg.get("contact_email", "")).strip()
        domain = str(cfg.get("domain", "")).strip()
        parsed = urllib.parse.urlsplit(domain)
        return bool(
            os.environ.get("BOJI_LEGAL_PUBLISH", "").strip() == "1"
            and operator
            and "your-domain" not in operator.lower()
            and re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", email)
            and str(cfg.get("icp_number", "")).strip()
            and parsed.scheme == "https"
            and parsed.hostname
            and parsed.username is None
            and parsed.password is None
            and parsed.path in ("", "/")
            and not parsed.query
            and not parsed.fragment
        )

    def _trusted_proxy(self) -> bool:
        # The service is deployed on loopback behind Nginx. Ignore client-supplied
        # forwarding headers for every other peer so IP throttling and Secure
        # cookie decisions cannot be spoofed by direct requests.
        peer = (self.client_address[0] or "").split("%", 1)[0]
        if peer.startswith("::ffff:"):
            peer = peer[7:]
        return peer in ("127.0.0.1", "::1")

    def client_ip(self) -> str:
        if self._trusted_proxy():
            forwarded = self.headers.get("X-Real-IP", "").strip()
            if not forwarded:
                forwarded = self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
            try:
                return str(__import__("ipaddress").ip_address(forwarded))
            except ValueError:
                pass
        return self.client_address[0]

    def send(self, code: int, body: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'")
        if self.is_https():
            self.send_header("Strict-Transport-Security", "max-age=31536000")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_html(self, text: str, code: int = 200, extra: dict | None = None) -> None:
        self.send(code, text.encode("utf-8"), "text/html; charset=utf-8", extra)

    def send_json(self, obj, code: int = 200, extra: dict | None = None) -> None:
        self.send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8", extra)

    def redirect(self, location: str) -> None:
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def read_json(self) -> dict:
        try:
            raw_length = self.headers.get("Content-Length")
            if raw_length is None:
                return {}
            length = int(raw_length)
            if length <= 0 or length > 5_000_000:
                return {}
            value = json.loads(self.rfile.read(length).decode("utf-8"))
            return value if isinstance(value, dict) else {}
        except Exception:
            return {}

    # ---- GET
    def do_GET(self):  # noqa: N802
        try:
            self.route_get()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            import traceback
            traceback.print_exc()
            self.send_json({"error": "internal error"}, 500)

    def route_get(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if hasattr(self, "_query"):
            del self._query
        if not path.startswith("/admin") and not path.startswith("/api/admin") and not self.public_site_ready():
            self.send_html("<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>网站配置中</title><body style=\"font:16px -apple-system,BlinkMacSystemFont,sans-serif;max-width:36rem;margin:18vh auto;padding:24px;color:#222\"><h1>网站正在配置</h1><p>协议与联系信息完成核对后会在这里开放。</p></body></html>", 503, {"Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow"})
            return
        cookies = self.cookies()
        lang = detect_lang(self, cookies.get("boji-lang"))
        theme = self.query("theme") if self.query("theme") in ("light", "dark", "auto") else (cookies.get("boji-theme") or "auto")

        if path == "/" or path == "/index.html":
            html_text = render_landing(lang, theme)
            self.send_html(html_text, extra=self._page_headers())
            return
        if path == "/legal":
            html_text = render_legal_home(lang, theme)
            self.send_html(html_text, extra=self._page_headers())
            return
        if len(path) > 1 and path[1:] in PAGE_ORDER:
            html_text = render_doc(path[1:], lang, theme)
            self.send_html(html_text if html_text else render_404(lang, theme),
                           200 if html_text else 404, extra=self._page_headers())
            return
        if path == "/sitemap.xml":
            self.send(200, render_sitemap().encode("utf-8"), "application/xml; charset=utf-8",
                      {"Cache-Control": "public, max-age=3600"})
            return
        m = re.match(r"^/doc/([a-z0-9-]+)$", path)
        if m:
            html_text = render_doc(m.group(1), lang, theme)
            if html_text is None:
                self.send_html(render_404(lang, theme), 404)
            else:
                self.send_html(html_text, extra=self._page_headers())
            return
        m = re.match(r"^/print/([a-z0-9-]+)$", path)
        if m:
            html_text = render_doc(m.group(1), lang, "light", print_view=True)
            self.send_html(html_text if html_text else render_404(lang, "light"),
                           200 if html_text else 404, extra=self._page_headers(noindex=True))
            return
        m = re.match(r"^/assets/([A-Za-z0-9._/-]+)$", path)
        if m:
            self.send_asset(m.group(1))
            return
        if path == "/favicon.ico":
            self.send_asset("favicon.png")
            return
        if path == "/robots.txt":
            self.send(200, b"User-agent: *\nAllow: /\nDisallow: /admin\n", "text/plain; charset=utf-8")
            return
        if path == "/admin":
            page = (ADMIN_HTML
                    .replace("__LANGS__", json.dumps(LANGS))
                    .replace("__LANGNATIVE__", json.dumps(LANG_NATIVE, ensure_ascii=False))
                    .replace("__DOCS__", json.dumps(
                        [{"id": d, "group": "legal"} for d in DOC_ORDER] + [{"id": p, "group": "page"} for p in PAGE_ORDER],
                        ensure_ascii=False)))
            self.send_html(page, extra={"Cache-Control": "no-store", "X-Robots-Tag": "noindex"})
            return
        if path == "/api/admin/session":
            self.api_session()
            return
        if path == "/api/admin/list":
            self.api_list()
            return
        m = re.match(r"^/api/admin/doc/([a-z0-9-]+)/([a-zA-Z-]+)$", path)
        if m:
            self.api_get_doc(m.group(1), m.group(2))
            return
        if path == "/api/admin/config":
            self.api_get_config()
            return
        if path == "/api/admin/export":
            self.api_export()
            return
        self.send_html(render_404(lang, theme), 404)

    def _page_headers(self, noindex: bool = False) -> dict:
        headers = {"Cache-Control": "no-cache"}
        if noindex:
            headers["X-Robots-Tag"] = "noindex"
        return headers

    def send_asset(self, name: str) -> None:
        allowed = {
            "app.css": "text/css; charset=utf-8",
            "app.js": "application/javascript; charset=utf-8",
            "BojiMark-light.svg": "image/svg+xml",
            "BojiMark-dark.svg": "image/svg+xml",
            "BojiMark-mono.svg": "image/svg+xml",
            "favicon.png": "image/png",
            "apple-touch-icon.png": "image/png",
            "screenshots/shot-home.png": "image/png",
            "screenshots/shot-training.png": "image/png",
            "screenshots/shot-chat.png": "image/png",
            "screenshots/shot-log.png": "image/png",
        }
        if name not in allowed:
            self.send_json({"error": "not found"}, 404)
            return
        f = ASSETS_DIR / name
        if not f.exists():
            self.send_json({"error": "not found"}, 404)
            return
        data = f.read_bytes()
        self.send(200, data, allowed[name], {"Cache-Control": "public, max-age=3600"})

    # ---- POST
    def do_POST(self):  # noqa: N802
        try:
            self.route_post()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            import traceback
            traceback.print_exc()
            self.send_json({"error": "internal error"}, 500)

    def route_post(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if hasattr(self, "_query"):
            del self._query
        if path == "/api/admin/login":
            self.api_login()
            return
        admin = self.require_admin()
        if admin is None:
            return
        if path == "/api/admin/logout":
            self.api_logout()
        elif path == "/api/admin/save":
            self.api_save()
        elif path == "/api/admin/restore":
            self.api_restore()
        elif path == "/api/admin/config/save":
            self.api_config_save()
        elif path == "/api/admin/import":
            self.api_import()
        elif path == "/api/admin/password":
            self.api_password()
        else:
            self.send_json({"error": "not found"}, 404)

    # ---- admin internals
    def current_session(self) -> dict | None:
        token = self.cookies().get("boji-admin")
        if not token:
            return None
        sessions = load_sessions()
        s = sessions.get(token)
        if not s or s.get("expires", 0) < time.time():
            return None
        s = dict(s)
        s["token"] = token
        return s

    def require_admin(self) -> dict | None:
        s = self.current_session()
        if s is None:
            self.send_json({"error": "unauthorized"}, 401)
            return None
        token = s["token"] if isinstance(s, dict) else s.get("token")
        if self.headers.get("X-CSRF-Token") != s.get("csrf"):
            self.send_json({"error": "csrf failed"}, 403)
            return None
        s["token"] = token
        return s

    def api_session(self):
        s = self.current_session()
        if not s:
            self.send_json({"error": "unauthorized"}, 401)
            return
        auth = _load_json(AUTH_FILE, {})
        self.send_json({"ok": True, "csrf": s["csrf"], "must_change": bool(auth.get("must_change"))})

    def api_login(self):
        ip = self.client_ip()
        if login_rate_limited(ip):
            self.send_json({"error": "尝试次数过多，请 10 分钟后再试"}, 429)
            return
        data = self.read_json()
        auth = init_auth()
        password = str(data.get("password", ""))
        if len(password) > 256 or not verify_password(auth, password):
            record_login_failure(ip)
            time.sleep(0.6)
            self.send_json({"error": "密码错误"}, 401)
            return
        token = secrets.token_urlsafe(32)
        sessions = load_sessions()
        now = time.time()
        for k, v in list(sessions.items()):
            if v.get("expires", 0) < now:
                del sessions[k]
        sessions[token] = {"csrf": secrets.token_urlsafe(24), "expires": now + 7 * 86400, "created": now}
        save_sessions(sessions)
        cookie = f"boji-admin={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={7 * 86400}"
        if self.is_https():
            cookie += "; Secure"
        self.send_json({"ok": True}, extra={"Set-Cookie": cookie})

    def api_logout(self):
        s = self.current_session()
        if s:
            sessions = load_sessions()
            sessions.pop(s["token"], None)
            save_sessions(sessions)
        self.send_json({"ok": True}, extra={"Set-Cookie": "boji-admin=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"})

    def api_list(self):
        store = get_store()
        docs = {}
        for doc_id in ALL_CONTENT_IDS:
            docs[doc_id] = {}
            for lang, entry in store["docs"].get(doc_id, {}).get("langs", {}).items():
                docs[doc_id][lang] = {
                    "title": entry.get("title", ""), "version": entry.get("version", ""),
                    "updated": entry.get("updated", ""), "effective": entry.get("effective", ""),
                    "edited": bool(entry.get("edited")),
                }
        self.send_json({"ok": True, "docs": docs})

    def api_get_doc(self, doc_id: str, lang: str):
        if doc_id not in ALL_CONTENT_IDS or lang not in LANGS:
            self.send_json({"error": "not found"}, 404)
            return
        store = get_store()
        entry = store["docs"].get(doc_id, {}).get("langs", {}).get(lang)
        if not entry:
            self.send_json({"error": "not found"}, 404)
            return
        self.send_json({"ok": True, "doc": entry})

    def api_save(self):
        data = self.read_json()
        doc_id, lang = data.get("doc"), data.get("lang")
        if doc_id not in ALL_CONTENT_IDS or lang not in LANGS:
            self.send_json({"error": "invalid doc or lang"}, 400)
            return
        body = str(data.get("body", ""))
        store = get_store()
        entry = store["docs"].setdefault(doc_id, {"langs": {}})["langs"].setdefault(lang, {})
        entry.update({
            "title": str(data.get("title", "")).strip() or doc_id,
            "description": str(data.get("description", "")),
            "version": str(data.get("version", "")).strip(),
            "effective": str(data.get("effective", "")).strip(),
            "updated": str(data.get("updated", "")).strip() or datetime.now().strftime("%Y-%m-%d"),
            "body": body,
            "edited": True,
            "edited_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
        _save_json(CONTENT_FILE, store)
        self.send_json({"ok": True})

    def api_restore(self):
        data = self.read_json()
        doc_id, lang = data.get("doc"), data.get("lang")
        if doc_id not in ALL_CONTENT_IDS or lang not in LANGS:
            self.send_json({"error": "invalid doc or lang"}, 400)
            return
        path = SEED_DIR / lang / f"{doc_id}.md"
        if not path.exists():
            self.send_json({"error": "seed missing"}, 404)
            return
        meta, body = parse_front_matter(path.read_text(encoding="utf-8"))
        store = get_store()
        store["docs"].setdefault(doc_id, {"langs": {}})["langs"][lang] = {
            "title": meta.get("title", doc_id), "description": meta.get("description", ""),
            "version": meta.get("version", "1.0.0"), "effective": meta.get("effective", ""),
            "updated": meta.get("updated", ""), "body": body, "edited": False, "edited_at": None,
        }
        _save_json(CONTENT_FILE, store)
        self.send_json({"ok": True})

    def api_get_config(self):
        self.send_json({"ok": True, **get_config()})

    def api_config_save(self):
        data = self.read_json()
        cfg = get_config()
        for key in ("operator_name", "contact_email", "domain", "icp_number", "app_store_url"):
            if key in data:
                value = str(data.get(key, "")).strip()
                if len(value) > 240:
                    self.send_json({"error": f"{key} 内容过长"}, 400)
                    return
                if key == "contact_email" and value and not re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", value):
                    self.send_json({"error": "联系邮箱格式不正确"}, 400)
                    return
                if key in ("domain", "app_store_url") and value:
                    parsed = urllib.parse.urlsplit(value)
                    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
                        self.send_json({"error": f"{key} 必须是有效的 HTTPS 地址"}, 400)
                        return
                    if key == "domain" and (parsed.path not in ("", "/") or parsed.query or parsed.fragment):
                        self.send_json({"error": "网站域名只填写 HTTPS 主机地址"}, 400)
                        return
                cfg[key] = value
        for key in ("site_names", "storage_location", "announcement"):
            if key in data and isinstance(data.get(key), dict):
                merged = dict(DEFAULT_CONFIG[key])
                for lk, lv in data[key].items():
                    if lk in ("zh-CN", "zh-TW", "*"):
                        merged[lk] = str(lv).strip()
                cfg[key] = merged
        _save_json(CONFIG_FILE, cfg)
        self.send_json({"ok": True})

    def api_export(self):
        payload = {
            "kind": "boji-legal-backup",
            "exported_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "config": get_config(),
            "content": get_store(),
        }
        body = json.dumps(payload, ensure_ascii=False, indent=1).encode("utf-8")
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.send(200, body, "application/json; charset=utf-8",
                  {"Content-Disposition": f'attachment; filename="boji-legal-backup-{stamp}.json"',
                   "Cache-Control": "no-store"})

    def api_import(self):
        data = self.read_json()
        if data.get("kind") != "boji-legal-backup" or not isinstance(data.get("content"), dict):
            self.send_json({"error": "不是有效的备份文件"}, 400)
            return
        content = data["content"]
        if not isinstance(content.get("docs"), dict):
            self.send_json({"error": "备份内容缺少 docs"}, 400)
            return
        _save_json(CONTENT_FILE, content)
        if isinstance(data.get("config"), dict):
            cfg = json.loads(json.dumps(DEFAULT_CONFIG))
            cfg.update({k: v for k, v in data["config"].items() if k in DEFAULT_CONFIG})
            _save_json(CONFIG_FILE, cfg)
        self.send_json({"ok": True})

    def api_password(self):
        data = self.read_json()
        auth = init_auth()
        if not verify_password(auth, str(data.get("old", ""))):
            self.send_json({"error": "当前密码错误"}, 401)
            return
        new = str(data.get("new", ""))
        if len(new) < 10:
            self.send_json({"error": "新密码至少 10 位"}, 400)
            return
        entry = make_auth_entry(new)
        entry["must_change"] = False
        _save_json(AUTH_FILE, entry)
        # invalidate all sessions
        save_sessions({})
        note = DATA_DIR / "ADMIN_INITIAL_PASSWORD.txt"
        if note.exists():
            note.unlink()
        self.send_json({"ok": True})


# ---------------------------------------------------------------- main

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8765")))
    ap.add_argument("--host", default=os.environ.get("HOST", "127.0.0.1"))
    args = ap.parse_args()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    import_seed()
    get_config()
    init_auth()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True

    def shutdown(_sig, _frm):
        print("\n[shutdown] bye", flush=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    print(f"BOJI CLUB 法律协议网站已启动 → http://{args.host}:{args.port}  （管理后台 /admin）", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
