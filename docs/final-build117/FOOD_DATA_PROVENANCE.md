# 食品数据来源与专业规则参考

生产文件：backend/food-catalog-production.json；来源USDA FoodData Central SR Legacy2018-04，7793条具完整能量、蛋白、脂肪、碳水字段的记录，CC0-1.0。正式发布目录保留食物ID、来源版本/URL和每100g数据；不是照片推断质量的证据。

官方数据说明：https://fdc.nal.usda.gov/download-datasets/
官方许可说明：https://fdc.nal.usda.gov/api-guide/
下载：https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip
原始ZIP SHA256：b80817294b8850530aaedf2e515c02593b1824f763a0ff356e5c2081643e6fd0
导入脚本：scripts/import-usda-foods.py（用--help查看入口）。中文别名：backend/food-aliases-zh.json。

训练进阶参考：ACSM2009 Progression models in resistance training for healthy adults，https://doi.org/10.1249/MSS.0b013e3181915670 。代码使用保守、有确认事实前提的规则，不代表已获专业机构审阅，不保证训练效果。

模型流式协议实现参照官方ChatCompletions streaming事件说明：https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events 。真实供应商验证使用现有LongCat兼容接口，未宣称调用OpenAI模型。
