# 让你的 AI 接进来 · Connecting your AI

食物本本身不带任何模型。估热量的是**你自己的 AI**——你们平时聊天的那个。它只需要会发 HTTP 请求
（大多数 agent 框架、Claude Code、带工具调用的机器人都行）。

*The diary ships without any model. The estimating is done by **your own AI** — the one you already talk to.
It only needs to be able to make HTTP requests.*

所有请求都带 `Authorization: Bearer <FOOD_LOG_TOKEN>`。

## 1. 拿到待估的条目

两种方式，选一种：

**A. 服务器推给 AI（webhook）**——设置 `AI_WEBHOOK_URL`（可选 `AI_WEBHOOK_TOKEN`）。
你停手 `AI_ASK_DELAY_S` 秒（默认 60）后，服务器把所有还没问过的待估条目一次性 POST 过去：

```json
{
  "prompt": "🍽️ 〔饮食记录·待估〕这几条还没有数：\n- #12（2026-01-01 午餐）牛肉面｜里面：一大碗，加了个蛋\n…",
  "entries": [{"id": 12, "date": "2026-01-01", "meal": "午餐", "text": "牛肉面", "detail": "一大碗，加了个蛋", "photo": "", "...": "..."}],
  "images": ["/uploads/1735700000-ab12cd34.jpg"]
}
```

`prompt` 可以原样交给你的 AI 当一条消息；`images` 是附的照片（营养成分表或者饭），
用 `GET /uploads/<文件名>`（带 token）下载了一起给它看。

**B. AI 自己来拉**——`GET /food/pending`，返回同样的结构。适合定时醒来的 agent。

## 2. 把数填回去

```http
PATCH /food/entry/12
Content-Type: application/json

{"kcal": 650, "protein": 30, "carbs": 80, "fat": 20,
 "portion": "约 520g", "detail": "面 250g、牛肉 80g、鸡蛋 1 个 ~50g", "by": "ai"}
```

- 带了 `kcal` 就算估好了（状态变成 done）。运动只填 `kcal`（消耗掉的）。
- `by: "ai"` 时，`detail` 存成 AI 的「逐样克数」版，用户写的原话不会被覆盖。
- App 里名字底下那行灰字会显示 AI 估的克数和整份多重。

## 3. 可选：AI 自己记、自己查

- **AI 替用户记一条**（用户在聊天里说「中午吃了牛肉面」）：
  `POST /food/entry` `{"meal":"午餐","text":"牛肉面","kcal":650,"protein":30,"carbs":80,"fat":20,"source":"ai"}`
  ——AI 记的必须带数。`meal` 是 `早餐 / 午餐 / 晚餐 / 加餐 / 运动` 之一，`date` 不填就是今天。
- **看某天**：`GET /food/day/2026-01-01` → 条目、目标、汇总（吃了多少、运动、净摄入、还剩多少到目标）。
- **查牌子货**：`GET /food/lookup?q=Ben%20%26%20Jerry%27s%20cookie%20dough&country=au` → Open Food Facts 每 100g 的数。
- **按条码查**：`GET /food/barcode/3017620422003`。

## 给 AI 的一句提醒 · a note for your AI's instructions

我们的经验：在 AI 的说明里写清楚**用户的目标是什么**，比写一堆规则有用。
比如「用户的目标是温和的热量缺口（或者增肌、或者吃够）：你帮忙把数记准就好，不劝多吃，也不说吃多了」。
AI 估数的时候最怕两种偏差——往少了估让人安心、往多了估让人愧疚——两种都别要，估准就是最大的帮忙。

*Tell your AI what the user's goal actually is, in one sentence. Then ask for accurate numbers — not reassuringly
low, not guilt-inducingly high.*
