"""General catalog-backed intake parsing. Model estimates are labeled, never catalog facts."""
import copy, math, re
import nutrition_engine as engine
MACROS=('calories','protein','carbs','fat')
# Explicit editable serving assumptions; nutrient values still come from catalog IDs.
COMMON={
 'tfda-R2400201':(['馒头','饅頭','白馒头','原味馒头'],{'个':80,'只':80},'暂按普通原味馒头每个80克估算，可改大小或重量'),
 'tfda-R2300901':(['包子','肉包','肉包子','猪肉包子'],{'个':100,'只':100},'暂按普通肉包每个100克估算，馅料或大小不同请修改'),
 'tfda-R2200801':(['饺子','水饺','水餃','肉饺子'],{'个':20,'只':20},'暂按熟肉水饺每个20克估算，大小和馅料可修改'),
 'tfda-R5000101':(['豆浆','豆漿'],{'杯':250,'碗':250,'盒':250},'暂按这份参考豆浆每杯250克估算，含糖量或品牌可修改'),
 'tfda-A0800101':(['燕麦','燕麦片'],{'份':40,'勺':10},'暂按干燕麦一份40克估算，冲泡所加奶或糖另计'),
}
def register(portions):
    catalog=engine._catalog(); by_id={x['food_id']:x for x in catalog.values()}
    for name,food in catalog.items():
        if not 2<=len(name)<=24 or not re.fullmatch(r'[\w（）()\-]+',name):continue
        canonical=food.get('name_zh') or food.get('name','')
        portions.setdefault(name,(canonical,{'份':100},.5,'暂按该食品参考条目一份100克估算，可修改实际重量与做法'))
    for food_id,(names,units,note) in COMMON.items():
        food=by_id.get(food_id)
        if not food:continue
        canonical=food.get('name_zh') or food.get('name','')
        for name in names:
            catalog[engine._normalize_name(name)]=food
            portions[name]=(canonical,units,.4,note)

def candidates(question):
    # Retrieve actual catalog rows before asking the model to normalize portions.
    found={}
    for name,food in engine._catalog().items():
        if 2<=len(name)<=24 and name in question:
            old=found.get(food['food_id'])
            if old is None or len(name)>old[0]:found[food['food_id']]=(len(name),food)
    values=sorted(found.values(),key=lambda row:-row[0])[:10]
    return [{'food_id':f['food_id'],'name':f.get('name_zh') or f.get('name'),
             'per_100g':f['per_100g'],'source_database':f['source_database']} for _,f in values]

def enrich_result(request,raw):
    value=copy.deepcopy(raw);coach=value.get('coach')
    if not isinstance(coach,dict):return value
    query=request['payload'].get('question','');allowed={x['food_id']:x for x in candidates(query)}
    targets=[c.get('payload',{}) for c in coach.get('card_requests',[]) if c.get('type')=='meal_draft']
    targets += [c.get('input',{}) for c in coach.get('capability_calls',[]) if c.get('capability') in ('nutrition.create_draft','nutrition.save_entry')]
    for target in targets:
        for meal in target.get('meals',[]):
            if not isinstance(meal,dict):continue
            inputs=meal.pop('nutrition_inputs131',None)
            if inputs is not None:
                valid=isinstance(inputs,list) and 1<=len(inputs)<=20
                totals={k:0 for k in MACROS};sources=[];grams=0
                for item in inputs if valid else []:
                    if not isinstance(item,dict):valid=False;break
                    food=allowed.get(item.get('food_id'));mass=item.get('grams')
                    if food is None or isinstance(mass,bool) or not isinstance(mass,(float,int)) or not math.isfinite(mass) or not 0<mass<=5000:valid=False;break
                    grams+=mass
                    for key in MACROS:totals[key]+=food['per_100g'][key]*mass/100
                    sources.append(food['source_database']+'/'+food['food_id'])
                if valid and totals['calories']<=10000 and all(totals[k]<=2000 for k in MACROS[1:]):
                    meal.update({k:round(v,1) for k,v in totals.items()});meal['nutritionSources']=list(dict.fromkeys(sources))[:8]
                    meal.update(estimated=True,requiresReview=True)
                    meal.setdefault('portion',f'约{grams:g}克，按所述做法估算，可修改份量')
                else:
                    # Invalid catalog IDs must not lend credibility to model numbers.
                    meal['nutritionSources']=['model_estimate:user_description']
                    meal.update(estimated=True,requiresReview=True)
            elif any(k in meal for k in MACROS):
                legitimate={food['source_database']+'/'+food['food_id'] for food in allowed.values()}
                declared=meal.get('nutritionSources')
                if not isinstance(declared,list) or not declared or any(x not in legitimate for x in declared):
                    meal['nutritionSources']=['model_estimate:user_description']
                meal.update(estimated=True,requiresReview=True)
    return value
