#!/usr/bin/env python3
import hashlib
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

DATA = Path(os.environ.get("EXERCISES_JSON", "/opt/dongzuo/dataset/data/exercises.json"))
PUBLIC_BASE = os.environ.get("PUBLIC_BASE", "https://dongzuo.gongxiang.cloud").rstrip("/")

with DATA.open(encoding="utf-8") as handle:
    ORIGINAL_EXERCISES = json.load(handle)
SUPPLEMENTAL_FILE = Path(__file__).with_name("exercise-supplemental.json")
SUPPLEMENTAL_EXERCISES = json.loads(SUPPLEMENTAL_FILE.read_text(encoding="utf-8")) if SUPPLEMENTAL_FILE.exists() else []
if {str(x["id"]) for x in ORIGINAL_EXERCISES} & {str(x["id"]) for x in SUPPLEMENTAL_EXERCISES}:
    raise RuntimeError("Supplemental exercise ID overlaps original dataset")
EXERCISES = ORIGINAL_EXERCISES + SUPPLEMENTAL_EXERCISES

COPY_NAMES = Path(__file__).with_name("exercise-names-zh.json")
NAME_ZH = json.loads(COPY_NAMES.read_text(encoding="utf-8")) if COPY_NAMES.exists() else {}
BY_ID = {str(item["id"]): item for item in EXERCISES}
CURATED_FILE = Path(__file__).with_name("exercise-catalog.json")
CURATED_ROWS = json.loads(CURATED_FILE.read_text(encoding="utf-8"))
CURATED = {row["id"]: row for row in CURATED_ROWS}
if len(CURATED_ROWS) != 678 or len(CURATED) != 678:
    raise RuntimeError("Invalid curated exercise catalog")
if len(ORIGINAL_EXERCISES) >= 678 and not set(CURATED).issubset(BY_ID):
    raise RuntimeError("Curated IDs missing from source dataset")
VISIBLE_EXERCISES = [BY_ID[row["id"]] for row in CURATED_ROWS if row["id"] in BY_ID]
PART_CODES = {"背":"back", "大腿":"upper legs", "核心":"waist", "肩":"shoulders", "手臂":"upper arms", "臀":"glutes", "胸":"chest", "小腿":"lower legs", "有氧与全身":"cardio"}
def display_part(item):
    row = CURATED.get(str(item["id"]))
    return PART_CODES[row["category_zh"]] if row else text(item.get("body_part") or item.get("category"))
ETAG = hashlib.sha256(b"bojiclub-exercise-api-curated678-v1" + CURATED_FILE.read_bytes() + DATA.read_bytes() + (COPY_NAMES.read_bytes() if COPY_NAMES.exists() else b"")).hexdigest()[:24]

def chinese_instruction(value):
    """Fix unambiguous wording without changing numbers, ranges or movement directions."""
    value = str(value or "")
    for old, new in {
        "电缆": "拉力器",
        "重复所需的重复次数": "按训练安排完成相应次数",
        "核心肌群参与": "核心肌群收紧",
        "核心参与": "核心收紧",
        "启动你的核心": "收紧核心",
        "铰接臀部": "屈髋（以髋部为轴前倾）",
        "腿筋": "大腿后侧肌群",
    }.items():
        value = value.replace(old, new)
    return value


def text(value):
    return str(value or "").strip()


def media_url(value):
    value = text(value).replace("\\", "/").lstrip("/")
    if value.startswith("images/") or value.startswith("videos/"):
        return f"{PUBLIC_BASE}/media/{value}"
    return None


def summary(item):
    return {
        "id": str(item["id"]),
        "name": text(item.get("name")),
        "name_zh": NAME_ZH.get(str(item["id"])),
        "body_part": display_part(item),
        "catalog_visible": str(item["id"]) in CURATED,
        "equipment_zh": CURATED.get(str(item["id"]), {}).get("equipment_zh"),
        "training_type_zh": CURATED.get(str(item["id"]), {}).get("training_type_zh"),
        "suggested_recording_unit": CURATED.get(str(item["id"]), {}).get("suggested_recording_unit"),
        "has_demo": bool(item.get("gif_url")),
        "equipment": text(item.get("equipment")),
        "target": text(item.get("target")),
        "muscle_group": text(item.get("muscle_group")),
        "secondary_muscles": item.get("secondary_muscles") or [],
        "image_url": media_url(item.get("image")),
        "gif_url": media_url(item.get("gif_url")),
    }


def detail(item, lang):
    result = summary(item)
    instructions = item.get("instructions") or {}
    if not isinstance(instructions, dict): instructions = {}
    steps = item.get("instruction_steps") or {}
    if not isinstance(steps, dict): steps = {}
    selected = lang if lang in instructions else "zh" if "zh" in instructions else "en"
    needs_review = selected == "zh" and str(item["id"]) == "0987"
    result.update({
        "language": selected,
        "instructions": "这个动作的文字说明正在核对，可先选择其他熟悉的动作。" if needs_review else chinese_instruction(text(instructions.get(selected))) if selected == "zh" else text(instructions.get(selected)),
        "instruction_steps": [] if needs_review else [chinese_instruction(step) for step in steps.get(selected) or []] if selected == "zh" else steps.get(selected) or [],
        "copy_review_needed": needs_review,
    })
    return result


CHINESE_TERMS = {
    '上斜哑铃卧推':'incline dumbbell bench press', '单臂哑铃划船':'one arm dumbbell row',
    '杠铃深蹲':'barbell squat', '徒手深蹲':'bodyweight squat', '哑铃卧推':'dumbbell bench press',
    '杠铃卧推':'barbell bench press', '跪姿俯卧撑':'knee push up', '俯卧撑':'push up',
    '坐姿划船':'seated cable row', '罗马尼亚硬拉':'romanian deadlift', '平板支撑':'plank',
    '哑铃推举':'dumbbell shoulder press', '哑铃弯举':'dumbbell curl', '高脚杯深蹲':'goblet squat',
    '弓步蹲':'lunge', '臀桥':'glute bridge', '卷腹':'crunch', '深蹲':'squat', '卧推':'bench press',
    '肩推':'shoulder press', '划船':'row', '硬拉':'deadlift', '弯举':'curl', '侧平举':'lateral raise',
    '胸部':'chest', '胸肌':'chest', '背部':'back', '肩部':'shoulders', '手臂':'upper arms',
    '腿部':'upper legs', '小腿':'calves', '核心':'waist', '腹部':'waist', '腹肌':'abs',
    '臀部':'glutes', '二头肌':'biceps', '三头肌':'triceps', '股四头肌':'quads', '腘绳肌':'hamstrings',
    '哑铃':'dumbbell', '杠铃':'barbell', '弹力带':'band', '壶铃':'kettlebell',
    '史密斯机':'smith machine', '拉力器':'cable', '绳索':'cable', '自重':'body weight',
    '徒手':'body weight', '有氧':'cardio', '跑步':'run', '跳绳':'rope', '引体向上':'pull up',
}


def search_terms(value):
    value=value.casefold()
    for key in sorted(CHINESE_TERMS, key=len, reverse=True):
        value=value.replace(key, ' '+CHINESE_TERMS[key]+' ')
    value=value.replace('bodyweight','body weight')
    return set(re.findall(r'[a-z0-9]+|[\u4e00-\u9fff]+',value))


MOVEMENT_CATALOG = json.loads(Path(__file__).with_name('movement-catalog.json').read_text(encoding='utf-8'))
def normalized_name(value): return ' '.join(re.findall(r'[a-z0-9]+|[\u3400-\u9fff]+',value.casefold()))
def search_copy(item):
    row = CURATED.get(str(item["id"]), {})
    return ' '.join([str(item["id"])] + [text(item.get(k)) for k in ('name','body_part','category','equipment','target','muscle_group')] + [row.get('name_zh',''),row.get('equipment_zh',''),row.get('category_zh',''),row.get('training_type_zh','')] + row.get('search_aliases_zh',[]))
SEARCH_INDEX = [(item, search_terms(search_copy(item))) for item in VISIBLE_EXERCISES]
EXACT_NAMES = {}
for item in EXERCISES: EXACT_NAMES.setdefault(normalized_name(item['name']),[]).append(item)
REVIEWED_NAMES = {}
for row in CURATED_ROWS:
    for value in [row['name'],row['name_zh']] + row.get('search_aliases_zh',[]):
        REVIEWED_NAMES.setdefault(normalized_name(value),row['id'])
REVIEWED_NAMES.update({'plank':'boji-basic-plank','body weight squat':'boji-basic-squat'})

def resolve_movement(query):
    key=normalized_name(query)
    if key in REVIEWED_NAMES:
        row=CURATED[REVIEWED_NAMES[key]];item=BY_ID.get(row['id'])
        if item is not None and item['name']==row['name'] and item['equipment']==row['equipment']:
            return summary(item)
        return None
    if key in MOVEMENT_CATALOG:
        record=MOVEMENT_CATALOG[key];item=BY_ID.get(record['library_id'])
        # Prevent a changed dataset from silently reusing an ID for another movement.
        if item is None or item['name']!=record['canonical_name'] or item['equipment']!=record['equipment']: return None
        return summary(item) if str(item['id']) in CURATED else None
    matches=EXACT_NAMES.get(key,[])
    return summary(matches[0]) if len(matches)==1 and str(matches[0]["id"]) in CURATED else None


class Handler(BaseHTTPRequestHandler):
    server_version = "BojiExerciseAPI/1.0"

    def log_message(self, fmt, *args):
        # Do not log tokens or query contents.
        pass

    def send_json(self, status, value, cache="no-store"):
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/v1/health":
            self.send_json(200, {"status": "ok", "count": len(VISIBLE_EXERCISES), "retained_count": len(ORIGINAL_EXERCISES), "supplemental_count": len(SUPPLEMENTAL_EXERCISES), "dataset": ETAG}, "public, max-age=60")
            return
        if parsed.path == "/api/v1/facets":
            self.send_json(200, {
                "body_parts": sorted({display_part(x) for x in VISIBLE_EXERCISES if display_part(x)}),
                "equipment": sorted({text(x.get("equipment")) for x in VISIBLE_EXERCISES if text(x.get("equipment"))}),
                "targets": sorted({text(x.get("target")) for x in VISIBLE_EXERCISES if text(x.get("target"))}),
                "training_types": sorted({x["training_type_zh"] for x in CURATED_ROWS}),
            }, "private, max-age=3600")
            return
        if parsed.path == "/api/v1/resolve":
            query = text(parse_qs(parsed.query).get('q',[''])[0])[:100]
            self.send_json(200,{'item':resolve_movement(query)},'private, max-age=300')
            return
        if parsed.path == "/api/v1/exercises":
            query = parse_qs(parsed.query)
            q = text(query.get("q", [""])[0]).casefold()[:100]
            body_part = text(query.get("body_part", [""])[0]).casefold()[:100]
            equipment = text(query.get("equipment", [""])[0]).casefold()[:100]
            target = text(query.get("target", [""])[0]).casefold()[:100]
            training_type = text(query.get("training_type", [""])[0])[:30]
            try:
                offset = max(0, int(query.get("offset", [0])[0]))
                limit = min(100, max(1, int(query.get("limit", [30])[0])))
            except (TypeError, ValueError):
                self.send_json(400, {"error": "invalid_pagination"})
                return
            query_terms = search_terms(q)
            matches = []
            for item, haystack_terms in SEARCH_INDEX:
                name = text(item.get("name")).casefold()
                chinese_name = NAME_ZH.get(str(item["id"]), "")
                chinese_match = bool(q and re.search(r"[\u3400-\u9fff]", q) and all(term in search_copy(item).casefold() for term in q.split()))
                if q and not query_terms:
                    continue
                if query_terms and not query_terms.issubset(haystack_terms) and not chinese_match:
                    continue
                if body_part and display_part(item).casefold() != body_part:
                    continue
                if equipment and text(item.get("equipment")).casefold() != equipment:
                    continue
                if training_type and CURATED[str(item["id"])]["training_type_zh"] != training_type:
                    continue
                if target and text(item.get("target")).casefold() != target:
                    continue
                score = 0
                if chinese_match:
                    score += 800 if q == chinese_name.casefold() else 400
                if name == q:
                    score += 1000
                if name.startswith(q):
                    score += 300
                if q and q in name:
                    score += 200
                score += sum(20 for term in query_terms if term in set(re.findall(r"[a-z0-9]+", name)))
                score -= len(name.split()) * 2
                matches.append((score, item))
            matches.sort(key=lambda pair: pair[0], reverse=bool(query_terms))
            page = [item for _, item in matches[offset:offset + limit]]
            self.send_json(200, {"total": len(matches), "offset": offset, "limit": limit, "items": [summary(x) for x in page]}, "no-store")
            return
        prefix = "/api/v1/exercises/"
        if parsed.path.startswith(prefix):
            exercise_id = unquote(parsed.path[len(prefix):])
            if "/" in exercise_id or len(exercise_id) > 64:
                self.send_json(404, {"error": "not_found"})
                return
            item = BY_ID.get(exercise_id)
            if not item:
                self.send_json(404, {"error": "not_found"})
                return
            lang = text(parse_qs(parsed.query).get("lang", ["zh"])[0])[:8]
            self.send_json(200, detail(item, lang), "private, max-age=3600")
            return
        self.send_json(404, {"error": "not_found"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
    server.daemon_threads = True
    server.serve_forever()
