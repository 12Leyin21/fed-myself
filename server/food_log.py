"""Food log — pure logic (no network, no database).

A calorie & macro diary designed to be shared with an AI companion:
the user writes what they ate in their own words; entries without numbers
are "pending" and get estimated by the AI (or by the user).

Targets come from either
- manual: daily kcal + protein typed in by the user
- body:   height / weight / age / activity → Mifflin-St Jeor BMR × activity factor

Exercise does NOT raise the target: calories burned are subtracted from what was eaten,
so  net = eaten − exercise  and  remaining = target − net.
The diary never judges: the bar fills towards the target, going over just stays full.
"""
from __future__ import annotations

import re

MEALS = ["早餐", "午餐", "晚餐", "加餐"]
EXERCISE = "运动"
KINDS = MEALS + [EXERCISE]

ACTIVITY = {             # 活动系数（Mifflin-St Jeor 常用那套）
    "sedentary": 1.2,    # 基本坐着
    "light": 1.375,      # 每周轻运动 1~3 次
    "moderate": 1.55,    # 每周认真运动 3~5 次
}

DEFAULT_SETTINGS = {
    "mode": "body",
    "height_cm": 165, "weight_kg": 60, "age": 30, "sex": "f",
    "activity": "sedentary",
    "kcal": 1800, "protein": 90,
}


def bmr(height_cm: float, weight_kg: float, age: float, sex: str = "f") -> float:
    base = 10 * weight_kg + 6.25 * height_cm - 5 * age
    return base - 161 if sex == "f" else base + 5


def targets(settings: dict | None) -> dict:
    """设置 → 每日目标 {kcal, protein, carbs, fat, bmr, tdee}。脂肪按 30% 热量，碳水填剩下的。"""
    s = {**DEFAULT_SETTINGS, **(settings or {})}
    b = bmr(float(s["height_cm"]), float(s["weight_kg"]), float(s["age"]), s.get("sex", "f"))
    tdee = b * ACTIVITY.get(s.get("activity"), 1.2)
    if s.get("mode") == "manual":
        kcal = float(s.get("kcal") or tdee)
        protein = float(s.get("protein") or 1.5 * float(s["weight_kg"]))
    else:
        kcal = tdee
        protein = 1.5 * float(s["weight_kg"])
    fat = kcal * 0.30 / 9
    carbs = max(0.0, (kcal - protein * 4 - fat * 9) / 4)
    return {"kcal": round(kcal), "protein": round(protein), "carbs": round(carbs),
            "fat": round(fat), "bmr": round(b), "tdee": round(tdee)}


def _num(v):
    try:
        f = float(v)
        return f if f >= 0 else None
    except (TypeError, ValueError):
        return None


def clean_entry(payload: dict) -> tuple[dict | None, str]:
    """An entry from the app or the AI → normalised fields. Returns (entry, error).
    No kcal = pending: waiting for the AI (or the user) to fill in the numbers."""
    kind = str(payload.get("meal") or "").strip()
    if kind not in KINDS:
        return None, f"meal 只能是 {'/'.join(KINDS)}"
    text = str(payload.get("text") or "").strip()[:300]
    if not text:
        return None, "写一下吃了什么 / 做了什么运动"
    entry = {"meal": kind, "text": text,
             "photo": str(payload.get("photo") or "").strip()[:300],
             # text = what was eaten; detail = what's in it, in the user's own words ("half an onion");
             # detail_est = the AI's gram-by-gram version ("onion ~75g"); portion = whole serving size
             "detail": str(payload.get("detail") or "").strip()[:400],
             "detail_est": str(payload.get("detail_est") or "").strip()[:400],
             "portion": str(payload.get("portion") or "").strip()[:40]}
    for k in ("kcal", "protein", "carbs", "fat"):
        entry[k] = _num(payload.get(k))
    if kind == EXERCISE:
        entry["protein"] = entry["carbs"] = entry["fat"] = None
    entry["status"] = "pending" if entry["kcal"] is None else "done"
    return entry, ""


def summary(entries: list, tgt: dict) -> dict:
    """一天的综述。只算已经有数的；待估的单独计数。"""
    intake = {"kcal": 0.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0}
    exercise = 0.0
    pending = 0
    for e in entries:
        if e.get("kcal") is None:
            pending += 1
            continue
        if e.get("meal") == EXERCISE:
            exercise += float(e["kcal"])
            continue
        for k in intake:
            intake[k] += float(e.get(k) or 0)
    net = intake["kcal"] - exercise
    out = {k: round(v) for k, v in intake.items()}
    out.update({
        "exercise": round(exercise),
        "net": round(net),
        "remaining": max(0, round(tgt["kcal"] - net)),     # 还剩多少到目标；到了就是 0，不出负数
        "reached": net >= tgt["kcal"],
        "pending": pending,
        "meals": {m: round(sum(float(e.get("kcal") or 0) for e in entries if e.get("meal") == m))
                  for m in KINDS},
    })
    return out


def _bare(text: str) -> str:
    return re.sub(r"\s*[（(][^（）()]*[）)]", "", str(text or "")).strip()


def day_blurb(entries: list, limit: int = 60) -> str:
    """列表页那一行：早餐:xx/xx · 午餐:xx……"""
    parts = []
    for m in MEALS:
        # only the food itself on the list page — amounts / ingredients in brackets are dropped
        items = [_bare(e["text"]) for e in entries if e.get("meal") == m]
        items = [x for x in items if x]
        if items:
            parts.append(f"{m}:" + "/".join(items))
    text = " · ".join(parts)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def estimate_prompt(pending: list, user_name: str = "") -> str:
    """The message handed to the AI: only the pending lines, nothing else from the user's life."""
    lines = []
    for e in pending:
        label = "时长" if e.get("meal") == EXERCISE else "里面"   # 运动那栏右边填的是多久
        inside = f"｜{label}：{e['detail']}" if e.get("detail") else ""
        pic = "｜附了照片" if str(e.get("photo") or "").startswith("/uploads/") else ""
        lines.append(f"- #{e['id']}（{e['date']} {e['meal']}）{e['text']}{inside}{pic}")
    has_photo = any(str(e.get("photo") or "").startswith("/uploads/") for e in pending)
    return (
        f"🍽️ 〔饮食记录·待估〕{user_name + '记的' if user_name else ''}这几条还没有数：\n" + "\n".join(lines) + "\n\n"
        "每条估一下热量和三大营养素，用 PATCH /food/entry/{id} 填回去："
        "{\"kcal\":…, \"protein\":…, \"carbs\":…, \"fat\":…, \"portion\":\"约 420g\", "
        "\"detail\":\"虾仁 8 个 ~80g、西红柿 100g、洋葱 ~75g\", \"by\":\"ai\"}（运动只填 kcal，是消耗掉的）。"
        "detail 把「里面」的东西逐样写上克数，写得模糊的（半颗、一把、几片）换成估的重量。"
        "按常见份量估，估准就好，别往多估也别往少估。\n"
        + ("附了照片的：拍的是营养成分表就照表上每 100g 的数乘吃的克数（没写克数就按一份 serving）；"
           "拍的是饭就看图估。牌子货可以先 GET /food/lookup?q=… 查。\n" if has_photo else "")
    )


# ── Nutrition lookup (Open Food Facts: free, open data, no API key) ──────────────
# Data © Open Food Facts contributors, ODbL. https://world.openfoodfacts.org

def _off_num(v) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return round(f, 1)


def off_products(data: dict, limit: int = 5) -> list[dict]:
    """Open Food Facts 搜索结果 → 几行干净的：名字、牌子、每 100g 的热量和三大营养素、一份多少。
    没有热量数字的跳过（没用）。"""
    out = []
    for p in (data or {}).get("products") or []:
        n = p.get("nutriments") or {}
        kcal = _off_num(n.get("energy-kcal_100g"))
        if kcal is None and _off_num(n.get("energy_100g")) is not None:
            kcal = round(_off_num(n.get("energy_100g")) / 4.184, 1)   # 只给了 kJ
        name = str(p.get("product_name") or "").strip()
        if kcal is None or not name:
            continue
        out.append({
            "name": name[:80],
            "brand": str(p.get("brands") or "").split(",")[0].strip()[:40],
            "kcal_100g": kcal,
            "protein_100g": _off_num(n.get("proteins_100g")),
            "carbs_100g": _off_num(n.get("carbohydrates_100g")),
            "fat_100g": _off_num(n.get("fat_100g")),
            "serving": str(p.get("serving_size") or "").strip()[:30],
            "kcal_serving": _off_num(n.get("energy-kcal_serving")),
        })
        if len(out) >= limit:
            break
    return out


def off_line(p: dict) -> str:
    macros = "/".join("?" if p.get(k) is None else f"{p[k]:g}" for k in ("protein_100g", "carbs_100g", "fat_100g"))
    serving = f"；一份 {p['serving']}" + (f" ≈ {p['kcal_serving']:g} kcal" if p.get("kcal_serving") else "") if p.get("serving") else ""
    brand = f"（{p['brand']}）" if p.get("brand") else ""
    pack = f"，整包 {p['package']}" if p.get("package") else ""
    return f"{p['name']}{brand}：每 100g {p['kcal_100g']:g} kcal，蛋白/碳水/脂肪 {macros} g{serving}{pack}"
