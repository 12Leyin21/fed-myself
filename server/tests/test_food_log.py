"""Food log pure-logic tests. Run: python3 server/tests/test_food_log.py"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import food_log as F  # noqa: E402

# example person: 170 cm / 65 kg / 28 y / female / sedentary
t = F.targets({"mode": "body", "height_cm": 170, "weight_kg": 65, "age": 28, "activity": "sedentary"})
assert t["bmr"] == 1412 and t["tdee"] == 1694 and t["kcal"] == 1694 and t["protein"] == 98, t
assert t["fat"] == round(1694 * 0.3 / 9) and t["carbs"] > 0
m = F.targets({"mode": "manual", "kcal": 1800, "protein": 90})
assert m["kcal"] == 1800 and m["protein"] == 90

# 条目：没 kcal = 待估；运动不要三大营养素；meal 必须合法
e, err = F.clean_entry({"meal": "午餐", "text": "蛋炒饭一碗"})
assert e["status"] == "pending" and e["kcal"] is None and not err
e, err = F.clean_entry({"meal": "运动", "text": "跑步30分钟", "kcal": 250, "protein": 9})
assert e["status"] == "done" and e["protein"] is None
assert F.clean_entry({"meal": "夜宵", "text": "x"})[0] is None
assert F.clean_entry({"meal": "早餐", "text": " "})[0] is None
assert F.clean_entry({"meal": "早餐", "text": "x", "kcal": -5})[0]["status"] == "pending"

# 综述：运动从吃进去的里扣，目标不变；还差不出负数；待估单独数
entries = [
    {"meal": "早餐", "text": "番茄炒蛋", "kcal": 400, "protein": 20, "carbs": 30, "fat": 20},
    {"meal": "午餐", "text": "饭", "kcal": 600, "protein": 25, "carbs": 80, "fat": 15},
    {"meal": "晚餐", "text": "待估的", "kcal": None},
    {"meal": "运动", "text": "跑步", "kcal": 300},
]
s = F.summary(entries, {"kcal": 1545})
assert s["kcal"] == 1000 and s["exercise"] == 300 and s["net"] == 700 and s["remaining"] == 845, s
assert s["pending"] == 1 and not s["reached"] and s["meals"]["早餐"] == 400 and s["meals"]["运动"] == 300
s = F.summary([{"meal": "午餐", "text": "x", "kcal": 2000}], {"kcal": 1545})
assert s["remaining"] == 0 and s["reached"]

assert F.day_blurb(entries) .startswith("早餐:番茄炒蛋 · 午餐:饭 · 晚餐:待估的")
p = F.estimate_prompt([{"id": 7, "date": "2026-09-25", "meal": "午餐", "text": "番茄炒蛋", "detail": "虾仁8个 半颗洋葱"}])
assert "#7" in p and "PATCH /food/entry" in p and "估准就好" in p and "里面：虾仁8个 半颗洋葱" in p and "portion" in p
e, _ = F.clean_entry({"meal": "早餐", "text": "番茄炒蛋", "detail": "虾仁8个 西红柿100g"})
assert e["detail"] == "虾仁8个 西红柿100g" and e["detail_est"] == "" and e["portion"] == ""
print("food log ok")

# nutrition lookup (Open Food Facts)
data = {"products": [
    {"product_name": "Cookie Dough", "brands": "Ben & Jerry's, Magnum", "serving_size": "100 g",
     "nutriments": {"energy-kcal_100g": 273, "proteins_100g": 4.2, "carbohydrates_100g": 31, "fat_100g": 15,
                    "energy-kcal_serving": 273}},
    {"product_name": "", "nutriments": {"energy-kcal_100g": 100}},                   # 没名字，跳过
    {"product_name": "只有千焦", "nutriments": {"energy_100g": 418.4}},              # kJ 换算
    {"product_name": "没热量", "nutriments": {"proteins_100g": 3}},                   # 没热量，跳过
]}
ps = F.off_products(data)
assert [p["name"] for p in ps] == ["Cookie Dough", "只有千焦"], ps
assert ps[0]["brand"] == "Ben & Jerry's" and ps[1]["kcal_100g"] == 100.0
assert F.off_line(ps[0]) == "Cookie Dough（Ben & Jerry's）：每 100g 273 kcal，蛋白/碳水/脂肪 4.2/31/15 g；一份 100 g ≈ 273 kcal", F.off_line(ps[0])
assert F.off_line(ps[1]) == "只有千焦：每 100g 100 kcal，蛋白/碳水/脂肪 ?/?/? g"
many = {"products": [{"product_name": f"Magnum {i}", "nutriments": {"energy-kcal_100g": 300 + i}} for i in range(20)]}
assert len(F.off_products(many)) == 5 and len(F.off_products(many, limit=12)) == 12   # 搜索页一次要 12 条
print("lookup ok")

# list-page line drops bracketed amounts
b = F.day_blurb([{"meal": "晚餐", "text": "牛肉面（牛肉+面条+葱花）"}, {"meal": "加餐", "text": "香蕉 (中号 1 根)"}], limit=200)
assert b == "晚餐:牛肉面 · 加餐:香蕉", b
print("blurb ok")
