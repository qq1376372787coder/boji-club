"""Common Chinese quantities, explicit serving assumptions, authoritative arithmetic.
Catalog nutrient values are measured per-100g references; serving size is still
an editable assumption, never a claim of measured intake or a medical target.
"""
import copy, re
import nutrition_engine
MACROS=('calories','protein','carbs','fat')
# Versioned app defaults; TFDA oil-stick sample supplies 54g/unit. The other
# defaults are explicitly serving assumptions, not claimed database measures.
PORTIONS={
 '鸡蛋':('水煮鸡蛋',{'个':50},.25,'按普通大小、未额外加油估算；可修改做法和份量'),
 '水煮鸡蛋':('水煮鸡蛋',{'个':50},.2,'按普通大小水煮蛋估算'),
 '煮鸡蛋':('水煮鸡蛋',{'个':50},.2,'按普通大小水煮蛋估算'),
 '全熟水煮蛋':('水煮鸡蛋',{'个':50},.2,'按普通大小水煮蛋估算'),
 '油条':('油条',{'根':54},.35,'按参考样品每根54克估算；大小和含油量差异较大'),
 '油條':('油条',{'根':54},.35,'按参考样品每根54克估算'),
 '米饭':('米饭',{'碗':180,'份':180},.3,'暂按每碗180克熟米饭估算'),
 '白米饭':('米饭',{'碗':180,'份':180},.3,'暂按每碗180克熟米饭估算'),
 '牛奶':('全脂牛奶',{'杯':250,'盒':250},.2,'暂按全脂牛奶每杯250毫升估算；可改品牌或脂肪含量'),
 '全脂牛奶':('全脂牛奶',{'杯':250,'盒':250},.2,'暂按每杯250毫升估算'),
 '苹果':('苹果',{'个':180},.3,'暂按可食部分180克估算'),
 '香蕉':('香蕉',{'根':100,'个':100},.3,'暂按可食部分100克估算'),
 '白面包':('白面包',{'片':30},.25,'暂按每片30克估算'),
}
import nutrition_intake131
nutrition_intake131.register(PORTIONS)
NUM=r'[零〇一二两三四五六七八九十百半\d]+(?:\.\d+)?'
UNIT=r'(?:公斤|千克|毫升|kg|ml|克|g|个|只|根|碗|杯|份|片|盒|袋|勺)'
def number(value):
 try:return float(value)
 except ValueError:pass
 if value=='半':return .5
 digits={'零':0,'〇':0,'一':1,'二':2,'两':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9}
 total=0;current=0
 for char in value:
  if char in digits:current=digits[char]
  elif char=='十':total+=(current or 1)*10;current=0
  elif char=='百':total+=(current or 1)*100;current=0
  else:return None
 return float(total+current)
def estimates(question):
 items=[];spans=[]
 names='|'.join(re.escape(n) for n in sorted(PORTIONS,key=len,reverse=True))
 patterns=[re.compile(r'(?P<q>'+NUM+r')\s*(?P<u>'+UNIT+r')\s*(?P<n>'+names+r')',re.I),
           re.compile(r'(?P<n>'+names+r')(?:吃了|吃|有|共|是|约|大约|\s){0,5}(?P<q>'+NUM+r')\s*(?P<u>'+UNIT+r')',re.I)]
 for pattern in patterns:
  for m in pattern.finditer(question):
   if any(m.start()<b and m.end()>a for a,b in spans):continue
   count=number(m['q']);unit=m['u'].lower();canonical,portions,band,note=PORTIONS[m['n']]
   if count is None or not .01<=count<=1000:continue
   food=nutrition_engine.match_food(canonical)
   if not food:continue
   if unit in ('g','克'):grams=count;band=.05;note='按你提供的可食重量计算'
   elif unit in ('kg','公斤','千克'):grams=count*1000;band=.05;note='按你提供的可食重量计算'
   elif unit=='ml' or unit=='毫升':
    if canonical!='全脂牛奶':continue
    grams=count*1.03;band=.1;note='按普通牛奶密度估算'
   elif unit in portions:
    grams=count*portions[unit]
    if canonical=='全脂牛奶':grams*=1.03
   else:continue
   totals={k:round(food['per_100g'][k]*grams/100,1) for k in MACROS}
   if totals['calories']>10000 or any(totals[k]>2000 for k in MACROS[1:]):continue
   items.append({'name':m['n'],'canonical_name':canonical,'amount':count,'unit':unit,'grams':round(grams,1),
     **totals,'low':{k:round(v*(1-band),1) for k,v in totals.items()},'high':{k:round(v*(1+band),1) for k,v in totals.items()},
     'portion':f'{count:g}{unit}；{note}','estimated':True,'requiresReview':True,
     'source_database':food['source_database'],'source_ref':food['food_id'],'source_url':food.get('source_url'),'assumption':note})
   spans.append(m.span())
 return items

def hypothetical(question):return bool(re.search(r'举例|假如|假设|比如|例如|如果|准备吃|打算吃|计划吃|还没吃|没吃|没喝|没有吃|没有喝|不曾吃',question))
def enrich_result(request, raw):
 result=copy.deepcopy(raw);coach=result.get('coach')
 if not isinstance(coach,dict):return result
 question=request['payload'].get('question','');values=estimates(question)
 if hypothetical(question):
  coach['card_requests']=[c for c in coach.get('card_requests',[]) if c.get('type') not in ('meal_draft',)]
  coach['capability_calls']=[c for c in coach.get('capability_calls',[]) if c.get('capability') not in ('nutrition.save_entry','nutrition.create_draft')]
  return result
 if not values:return result
 targets=[c.get('payload',{}) for c in coach.get('card_requests',[]) if c.get('type')=='meal_draft']
 targets += [c.get('input',{}) for c in coach.get('capability_calls',[]) if c.get('capability') in ('nutrition.save_entry','nutrition.create_draft')]
 for target in targets:
  for meal in target.get('meals',[]):
   normalized=re.sub(NUM+'|'+UNIT+r'|[\s（）()]+','',meal.get('name',''))
   found=next((v for v in values if meal.get('name') in (v['name'],v['canonical_name']) or normalized in (v['name'],v['canonical_name'])),None)
   if found and sum(v['canonical_name']==found['canonical_name'] for v in values)==1:
    for k in MACROS:meal[k]=found[k]
    meal.update(portion=found['portion'],estimated=True,requiresReview=True,nutritionSources=[found['source_database']+'/'+found['source_ref']])
 return result

def fast_result(request):
    p=request['payload'];q=p.get('question','')
    if p.get('purpose','dialogue')!='dialogue' or p.get('images') or p.get('_references') or p.get('deep_analysis'):return None
    if re.search(r'不是|说错|改成|改为|其实|更正|不舒服|过敏|胸痛|晕倒',q):return None
    values=estimates(q)
    if not values:return None
    rest=q
    names='|'.join(re.escape(n) for n in sorted(PORTIONS,key=len,reverse=True))
    rest=re.sub(NUM+r'\s*'+UNIT+r'\s*(?:'+names+r')','',rest,flags=re.I)
    rest=re.sub(r'(?:'+names+r')(?:吃了|吃|有|共|是|约|大约|\s){0,5}'+NUM+r'\s*'+UNIT,'',rest,flags=re.I)
    words=r'我|今天|刚刚|刚才|早餐|午餐|晚餐|加餐|早上|中午|晚上|请问|请|帮我|记录|登记|保存|吃了|喝了|吃|喝|帮|一下|需要|热量|多少|大概|大约|卡路里|千卡|蛋白质|蛋白|营养|计算|算|的|和|还有|以及|是|想|现在|如果|假如|假设|比如|举例|例如|了|有|吗'
    if re.sub(words+r'|[\s，,。.!！?？、：:]','',rest):return None
    import coach_core
    lines=['按常见份量估算，可修改大小、做法或重量：']
    for v in values:
        lines.append(f"{v['amount']:g}{v['unit']}{v['name']}：约 {v['calories']:g} 千卡（参考范围 {v['low']['calories']:g}—{v['high']['calories']:g}），蛋白 {v['protein']:g}g、碳水 {v['carbs']:g}g、脂肪 {v['fat']:g}g。\n{v['assumption']}。")
    coach={'answer':'\n\n'.join(lines),'source_ids':[x['id'] for x in coach_core.evidence(p)][:14],'actions':[]}
    if not hypothetical(q) and re.search(r'吃了|喝了|刚吃|刚喝|记录|登记|保存',q):
        category=next((c for c in ('早餐','午餐','晚餐','加餐') if c in q),'加餐')
        meals=[{'name':v['name'],'category':category,**{k:v[k] for k in MACROS},'portion':v['portion'],'estimated':True,'requiresReview':True,'nutritionSources':[v['source_database']+'/'+v['source_ref']]} for v in values]
        payload={'date':request['date'],'meals':meals}
        whitelist={x['capability'] for x in p.get('capabilities',[])}
        if 'nutrition.create_draft' in whitelist:coach['capability_calls']=[{'capability':'nutrition.create_draft','input':payload}]
        else:coach['card_requests']=[{'type':'meal_draft','payload':payload}]
        coach['answer']+='\n\n份量和餐别可修改，确认后再保存。'
    return {'kind':'coach','notes':[],'coach':coach}
