# API · 给自己写界面的人（PWA / 网页 / 别的 App）

iOS 页面只是其中一个客户端。服务器是普通的 JSON 接口，PWA、网页、安卓、小程序……都能接。
*The iOS screens are just one client. Anything that can make HTTP requests can use the server.*

所有请求带 `Authorization: Bearer <FOOD_LOG_TOKEN>`。
PWA 如果跟服务器不在同一个域名下，部署时设 `FOOD_LOG_CORS=https://你的-pwa-域名`（多个用逗号隔开）。

| 做什么 | 请求 | 说明 |
|---|---|---|
| 列表页 | `GET /food/days?limit=60&q=` | 每天一张卡：`date` `kcal` `net` `pending` `blurb`（一行摘要）`photo`（封面） |
| 某一天 | `GET /food/day/{YYYY-MM-DD}` | `entries` `targets` `summary`（吃了多少、运动、净摄入、`remaining` 还剩多少到目标）`cover` |
| 记一条 | `POST /food/entry` | `{meal, text, detail?, kcal?, protein?, carbs?, fat?, photo?, date?}`；没 `kcal` 就是待估 |
| 改 / 填数 | `PATCH /food/entry/{id}` | 同上的字段；带 `kcal` 就算估好了 |
| 删 | `DELETE /food/entry/{id}` | |
| 上传照片 | `POST /food/upload?name=x.jpg` | body 是图片原始字节 → `{"url": "/uploads/…"}`，再把 url 填进条目的 `photo` |
| 显示照片 | `GET /uploads/{文件}` | `<img>` 带不了头，可以用 `?token=<FOOD_LOG_TOKEN>` |
| 列表封面 | `POST /food/cover` | `{date, url}`；url 空 = 恢复成第一张 |
| 目标设置 | `GET/POST /food/settings` | `mode`（`body` / `manual`）、`height_cm` `weight_kg` `age` `sex` `activity`、`kcal` `protein` |
| 按条码查 | `GET /food/barcode/{条码}` | Open Food Facts：`product.kcal_100g` 等 |
| 按名字查 | `GET /food/lookup?q=…&country=au&limit=12` | 同上；`limit` 1–20，默认 5（app 的「搜名字」页要 12 条） |
| 待估 | `GET /food/pending` | 给 AI 用，见 [connect-your-ai.md](connect-your-ai.md) |

`meal` 是 `早餐 / 午餐 / 晚餐 / 加餐 / 运动` 之一。运动那条 `text` 写练了什么，`detail` 写多久，`kcal` 是消耗。

**导入的条目**（比如手表锻炼）带 `ext_id` 和 `source: "watch"`：同一个 `ext_id` 只会记一次，用户删掉的也不会再导回来。

**网页上做扫码**：iOS 页面用系统的 VisionKit；网页里可以用浏览器的 `BarcodeDetector`（Chrome / 安卓）或者
[zxing-js](https://github.com/zxing-js/library) 之类的库拿到条码，再调 `/food/barcode/{条码}`。
拍营养表就是普通的 `<input type="file" accept="image/*" capture="environment">` + `/food/upload`。
**Apple Watch 导入只有 iOS 原生 App 能做**（要 HealthKit），PWA 读不到。
