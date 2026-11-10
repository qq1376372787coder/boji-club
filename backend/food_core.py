"""Validated per-food estimates; total nutrients are derived, never model totals."""
import uuid

try:
    import nutrition_engine
except ImportError:  # pragma: no cover - module lives beside this file at runtime
    nutrition_engine = None


def clean_food(result, notes, validators, source='photo'):
    text, number, sequence = validators
    if result['kind'] != 'meal' or type(result['is_food']) is not bool:
        raise ValueError('wrong food result')
    if not result['is_food']:
        return {'kind': 'meal', 'is_food': False, 'estimated': True, 'name': '未识别到食物',
                'notes': notes, 'components': [], 'calories': 0, 'protein': 0, 'carbs': 0, 'fat': 0}
    components = []
    for item in sequence(result['components'], 20, 1):
        unit = text(item['unit'], 10)
        basis = item['basis']
        allowed_basis = ('described', 'assumed') if source == 'text' else ('visible', 'assumed')
        if unit not in ('g', 'ml', '个', '份', '碗', '杯', '片', '根', '袋', '盒') or basis not in allowed_basis:
            raise ValueError('invalid food metadata')
        components.append({
            'id': str(uuid.uuid4()), 'name': text(item['name'], 100),
            'amount': number(item['amount'], .01, 10000), 'unit': unit, 'basis': basis,
            'details': [text(value, 200) for value in sequence(item.get('details', []), 8)],
            **{key: number(item[key], 0, 10000 if key == 'calories' else 2000)
               for key in ('calories', 'protein', 'carbs', 'fat')}
        })
        component = components[-1]
        component.update({'sourceKind': 'estimate', 'sourceDatabase': None,
                          'uncertaintyFlags': ['portion_estimated', 'portion_total_not_per_100g'],
                          'requiresReview': True,
                          'confidenceLow': round(component['calories'] * .65, 2),
                          'confidenceHigh': round(component['calories'] * 1.35, 2)})
        # Phase 3: the deterministic engine owns nutrients whenever mass and
        # trusted per-100g evidence exist. Volume is never treated as grams
        # without an explicit density. Model-declared database/label sources
        # are not trusted; only a catalog match or user/label verification is.
        per_100g = item.get('per_100g') or item.get('label_per_100g')
        engine_input = {
            'name': component['name'], 'food_id': text(item.get('food_id', ''), 80, True) or None,
            'amount': component['amount'], 'unit': unit,
            'edible_grams': item.get('edible_grams'),
            'reported_totals': {key:component[key] for key in ('calories','protein','carbs','fat')},
            'source_kind': text(item.get('source_kind', 'estimate'), 30),
            'per_100g': per_100g if isinstance(per_100g, dict) else None,
            'preparation': text(item.get('preparation', ''), 60, True),
            'source_ref': text(item.get('source_ref', ''), 80, True),
            'density_g_per_ml': item.get('density_g_per_ml'),
            # This is a model-output boundary, not a user verification event.
            # Model JSON cannot grant itself either trust level.
            'amount_confirmed': False,
            'user_confirmed': False,
            'label_verified': False,
        }
        if nutrition_engine is not None:
            try:
                computed = nutrition_engine.compute_item(engine_input, use_catalog=True)
            except ValueError as error:
                if isinstance(per_100g, dict):
                    raise ValueError('invalid per-100g nutrition evidence') from error
                computed = None
            if computed is not None:
                if all(computed.nutrients[key] is not None for key in ('calories', 'protein', 'carbs', 'fat')):
                    component.update({
                        'calories': computed.nutrients['calories'], 'protein': computed.nutrients['protein'],
                        'carbs': computed.nutrients['carbs'], 'fat': computed.nutrients['fat'],
                    })
                component.update({
                    'nutritionEngine': nutrition_engine.ENGINE_VERSION,
                    'sourceKind': computed.source_kind,
                    'sourceRef': computed.source_ref,
                    'sourceDatabase': computed.source_database,
                    'sourceVersion': computed.source_version,
                    'confidenceLow': computed.low.get('calories'),
                    'confidenceHigh': computed.high.get('calories'),
                    'edibleGrams': computed.edible_grams,
                    'uncertaintyFlags': list(computed.flags),
                })
                if any(value is None for value in computed.nutrients.values()):
                    component['uncertaintyFlags'] = sorted(set(component['uncertaintyFlags'] + ['nutrition_unknown']))
                    component['requiresReview'] = True
        mass = sum(component[k] for k in ('protein', 'carbs', 'fat'))
        if unit == 'g' and mass > component['amount'] * 1.25 + 2:
            raise ValueError('nutrient mass exceeds food amount')
        energy = 4 * (component['protein'] + component['carbs']) + 9 * component['fat']
        if energy > 50 and (component['calories'] < energy * .35 - 50 or component['calories'] > energy * 1.8 + 150):
            raise ValueError('inconsistent nutrient energy')
    totals = {key: round(sum(item[key] for item in components), 2)
              for key in ('calories', 'protein', 'carbs', 'fat')}
    if totals['calories'] > 10000 or any(totals[k] > 2000 for k in ('protein', 'carbs', 'fat')):
        raise ValueError('meal exceeds bounds')
    review = any(component.get('requiresReview') or component.get('uncertaintyFlags') for component in components)
    sources = sorted({component.get('sourceDatabase') for component in components if component.get('sourceDatabase')})
    return {'kind': 'meal', 'is_food': True, 'estimated': True, 'name': text(result['name'], 100),
            'notes': notes, 'components': components, **totals,
            'requiresReview': review or any(component.get('sourceKind') == 'estimate' for component in components),
            'nutritionSources': sources}


def clean_meal_batch(result, notes, validators, iso_date, upper_date):
    text, number, sequence = validators
    if result['kind'] != 'meal_batch':
        raise ValueError('wrong batch result')
    meals = []
    component_count = 0
    for index, item in enumerate(sequence(result['meals'], 6)):
        date = iso_date(item['date']).isoformat()
        if date > upper_date:
            raise ValueError('future meal')
        category = text(item['category'], 10)
        if category not in ('早餐', '午餐', '晚餐', '加餐') or item.get('is_food', True) is not True:
            raise ValueError('invalid batch meal')
        item_notes = [text(n, 500) for n in sequence(item.get('notes', []), 10)]
        meal = clean_food({**item, 'kind':'meal', 'is_food':True}, item_notes, validators, 'text')
        component_count += len(meal['components'])
        if component_count > 40:
            raise ValueError('too many batch components')
        meal.pop('kind'); meal.pop('is_food')
        meals.append({'id':'m'+str(index+1), 'date':date, 'category':category, **meal})
    if not meals and not notes:
        raise ValueError('empty batch without explanation')
    return {'kind':'meal_batch', 'estimated':True, 'notes':notes, 'meals':meals}
