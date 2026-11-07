#!/usr/bin/env python3
"""Reproducibly derive per-100g facts from USDA FDC SR Legacy CSV (CC0).
No model-generated nutrient values. Run with the official ZIP as argument.
"""
import csv
import hashlib
import io
import json
import sys
import zipfile
from pathlib import Path

SOURCE_URL = 'https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip'
NUTRIENTS = {'1008': 'calories', '1003': 'protein', '1004': 'fat', '1005': 'carbs'}


def build(archive, target):
    path = Path(archive)
    with zipfile.ZipFile(path) as z:
        def rows(name):
            member = next(n for n in z.namelist() if n.endswith('/' + name))
            return csv.DictReader(io.TextIOWrapper(z.open(member), encoding='utf-8-sig'))
        facts = {}
        for row in rows('food_nutrient.csv'):
            key = NUTRIENTS.get(row['nutrient_id'])
            if key and row['amount'] != '':
                facts.setdefault(row['fdc_id'], {})[key] = float(row['amount'])
        foods = []
        for row in rows('food.csv'):
            nutrients = facts.get(row['fdc_id'], {})
            if set(nutrients) != set(NUTRIENTS.values()):
                continue
            foods.append({'food_id': 'usda-sr-' + row['fdc_id'], 'name': row['description'],
                          'description_en': row['description'], 'aliases': [], 'per_100g': nutrients,
                          'source_database': 'USDA_FDC_SR_LEGACY', 'source_version': '2018-04',
                          'source_url': 'https://fdc.nal.usda.gov/food-details/' + row['fdc_id'] + '/nutrients'})
    result = {'source_database': 'USDA_FDC_SR_LEGACY', 'source_version': '2018-04',
              'source_url': SOURCE_URL, 'source_zip_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
              'license': 'CC0-1.0', 'nutrient_basis': 'per_100g_edible_portion', 'foods': foods}
    Path(target).write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
    print(json.dumps({'foods': len(foods), 'sha256': result['source_zip_sha256']}))

if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2])
