import json,re
from pathlib import Path
ROWS=json.loads(Path(__file__).with_name('exercise-catalog.json').read_text(encoding='utf-8'))
BY_ID={x['id']:x for x in ROWS}
if len(ROWS)!=678 or len(BY_ID)!=678:raise RuntimeError('Invalid curated exercise catalog')
def normalize(value):return ' '.join(re.findall(r'[a-z0-9]+|[\u3400-\u9fff]+',str(value).casefold()))
BY_QUERY={normalize(x['name']):x for x in ROWS}
for row in ROWS:
 for label in [row['name_zh']]+row.get('search_aliases_zh',[]):BY_QUERY.setdefault(normalize(label),row)
# Explicitly reviewed common English aliases; never use fuzzy matching for IDs.
ALIASES={'plank':'boji-basic-plank','body weight squat':'boji-basic-squat','barbell squat':'0043','barbell row':'0027','bodyweight lunge':'3470','lunge':'3470','knee push up':'3211','kneeling push up':'3211','glute bridge':'3013','bodyweight glute bridge':'3013','crunch':'0274','side plank':'0705','calf raise':'1373','jumping jack':'3224','dumbbell curl':'0294','dumbbell shoulder press':'0426','dumbbell row':'0293','one arm dumbbell row':'0292','incline dumbbell bench press':'0314','band row':'3144','band curl':'0968','band pull apart':'0993','kettlebell row':'0541','pull up':'0652','chin up':'1326','lat pulldown':'0150'}
for query,id in ALIASES.items():BY_QUERY[normalize(query)]=BY_ID[id]
def recommended_movement(query,legacy=None):
 key=normalize(query)
 if key in BY_QUERY:return BY_QUERY[key]
 id=(legacy or {}).get(key,{}).get('library_id')
 return BY_ID.get(id)
def resolve_generated_movement(exercise, legacy=None):
 query=exercise.get('library_query','')
 by_query=recommended_movement(query,legacy) if isinstance(query,str) else None
 explicit=exercise.get('library_id')
 if explicit is not None:
  if not isinstance(explicit,str) or explicit not in BY_ID:raise ValueError('invalid catalog ID')
  by_id=BY_ID[explicit]
  legacy_id=(legacy or {}).get(normalize(query),{}).get('library_id')
  if (by_query and by_query['id']!=by_id['id']) or (by_query is None and legacy_id and legacy_id not in BY_ID):raise ValueError('conflicting catalog references')
  return by_id
 return by_query

def candidate_prompt(allowed_ids=None, exclude_ids=None):
 # P0 动作禁忌拦截改动1：自动制定候选池只收 difficulty_zh=='常规'（10 个进阶项出池）；
 # exclude_ids 用于按用户身体情况再剔除 avoid 动作（exercise_risk.excluded_for）。
 excluded=set(exclude_ids or ())
 rows=[x for x in ROWS if (x['id'] in allowed_ids if allowed_ids is not None else x['selection_tier_zh']=='基础常用' and x['training_type_zh'] in ('力量／稳定性','有氧') and x['difficulty_zh']=='常规') and x['id'] not in excluded]
 compact=[]
 for row in rows:
  item={k:row[k] for k in ('id','name','name_zh','category_zh')}
  if row['suggested_recording_unit']=='time':item['unit']='time'
  if row['training_type_zh']=='有氧':item['type']='有氧'
  compact.append(item)
 return '自动制定优先使用基础常用动作；扩展库仍可供用户手动添加和导入。每天仍为3至5个动作；目录unit=time表示按秒，未标unit默认按次。type=有氧表示持续有氧，按训练时间安排，填写durationSeconds，不能写成10次；持续有氧通常安排一段可完成的时间，并计入用户单次可用时间。不强制每堂都加有氧，不得用有氧或拉伸凑够力量动作数量，不能仅因用户体重较高就强制高冲击运动。新生成的训练动作只能从下列推荐目录选取，每个动作必须填写目录里的字符串library_id，保留前导零；library_query填写对应原英文名，不自行改写。不得推荐目录外的旧动作，不把负重或进阶动作当作标准徒手版本。中文名称使用对应name_zh。目录：'+json.dumps(compact,ensure_ascii=False,separators=(',',':'))
