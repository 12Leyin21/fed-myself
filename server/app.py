"""Food log server — a small FastAPI app that the iOS client (and your AI) talk to.

Run:
    pip install -r requirements.txt
    FOOD_LOG_TOKEN=change-me uvicorn app:app --host 0.0.0.0 --port 8000

Environment:
    FOOD_LOG_TOKEN     required. Every request needs  Authorization: Bearer <token>
    FOOD_LOG_DATA      where the SQLite db, settings and photos live (default ./data)
    FOOD_LOG_TZ        your timezone for "today", e.g. Asia/Shanghai (default UTC)
    AI_WEBHOOK_URL     optional. When entries are waiting to be estimated, POST them here
                       (see docs/connect-your-ai.md). Without it, your AI can poll GET /food/pending.
    AI_WEBHOOK_TOKEN   optional bearer token sent with the webhook
    AI_ASK_DELAY_S     how long to wait after the last pending entry before asking (default 60)
    FOOD_LOG_USER_NAME optional. How the prompt names the person logging ("小满记的这几条还没有数")
    FOOD_LOG_CORS      optional, for web / PWA clients: comma-separated origins allowed to call the API,
                       e.g. https://my-pwa.example (use * only for local testing)
"""
from __future__ import annotations

import asyncio
import json
import os
import secrets
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

import food_log

TOKEN = os.environ.get("FOOD_LOG_TOKEN", "").strip()
DATA = Path(os.environ.get("FOOD_LOG_DATA", "./data"))
TZ = ZoneInfo(os.environ.get("FOOD_LOG_TZ", "UTC"))
WEBHOOK = os.environ.get("AI_WEBHOOK_URL", "").strip()
WEBHOOK_TOKEN = os.environ.get("AI_WEBHOOK_TOKEN", "").strip()
ASK_DELAY_S = float(os.environ.get("AI_ASK_DELAY_S", "60"))
USER_NAME = os.environ.get("FOOD_LOG_USER_NAME", "").strip()[:20]

DATA.mkdir(parents=True, exist_ok=True)
UPLOADS = DATA / "uploads"
UPLOADS.mkdir(exist_ok=True)
DB = DATA / "food.db"
SETTINGS = DATA / "settings.json"
COVERS = DATA / "covers.json"   # the list-page photo the user picked for each day
DELETED_EXT = DATA / "deleted-ext.json"   # imported workouts the user deleted — never import them again


def deleted_ext() -> set:
    try:
        return set(json.loads(DELETED_EXT.read_text("utf-8")))
    except Exception:
        return set()
UA = {"User-Agent": "food-log/1.0 (personal food diary)"}

app = FastAPI(title="Food Log")

CORS = [o.strip() for o in os.environ.get("FOOD_LOG_CORS", "").split(",") if o.strip()]
if CORS:   # browsers (PWAs) on another origin need this; native apps don't
    app.add_middleware(CORSMiddleware, allow_origins=CORS, allow_methods=["*"],
                       allow_headers=["Authorization", "Content-Type"])


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    return conn


with db() as _c:
    _c.execute("""
        CREATE TABLE IF NOT EXISTS food_entries (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         TEXT NOT NULL,
            date       TEXT NOT NULL,
            meal       TEXT NOT NULL,
            text       TEXT NOT NULL,
            kcal       REAL, protein REAL, carbs REAL, fat REAL,
            photo      TEXT NOT NULL DEFAULT '',
            source     TEXT NOT NULL DEFAULT 'user',   -- user | ai
            status     TEXT NOT NULL DEFAULT 'pending', -- pending | done
            asked_at   TEXT NOT NULL DEFAULT '',
            detail     TEXT NOT NULL DEFAULT '',
            detail_est TEXT NOT NULL DEFAULT '',
            portion    TEXT NOT NULL DEFAULT '',
            ext_id     TEXT NOT NULL DEFAULT ''             -- e.g. an Apple Watch workout UUID
        )""")
    _cols = {r[1] for r in _c.execute("PRAGMA table_info(food_entries)")}
    if "ext_id" not in _cols:
        _c.execute("ALTER TABLE food_entries ADD COLUMN ext_id TEXT NOT NULL DEFAULT ''")


def check_auth(request: Request) -> None:
    if not TOKEN:
        raise HTTPException(status_code=500, detail="FOOD_LOG_TOKEN is not set")
    got = request.headers.get("authorization", "")
    if not secrets.compare_digest(got, f"Bearer {TOKEN}"):
        raise HTTPException(status_code=401, detail="unauthorized")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def today() -> str:
    return datetime.now(TZ).strftime("%Y-%m-%d")


def load_settings() -> dict:
    try:
        return {**food_log.DEFAULT_SETTINGS, **json.loads(SETTINGS.read_text("utf-8"))}
    except Exception:
        return dict(food_log.DEFAULT_SETTINGS)


def rows(where: str = "", args: tuple = ()) -> list[dict]:
    with db() as conn:
        return [dict(r) for r in conn.execute(f"SELECT * FROM food_entries {where} ORDER BY date, id", args)]


def load_covers() -> dict:
    try:
        return json.loads(COVERS.read_text("utf-8"))
    except Exception:
        return {}


def cover_for(date: str, entries: list[dict]) -> str:
    """The day's cover: the one the user picked (if it still exists), else the first photo."""
    shots = [e["photo"] for e in entries if e.get("photo")]
    chosen = load_covers().get(date, "")
    return chosen if chosen in shots else (shots[0] if shots else "")


def day(date: str) -> dict:
    entries = rows("WHERE date = ?", (date,))
    tgt = food_log.targets(load_settings())
    return {"date": date, "entries": entries, "targets": tgt, "summary": food_log.summary(entries, tgt),
            "cover": cover_for(date, entries)}


# ── asking the AI ─────────────────────────────────────────────────────────────
_ask = {"task": None}


def pending_payload(entries: list[dict]) -> dict:
    return {"prompt": food_log.estimate_prompt(entries, USER_NAME),
            "entries": entries,
            "images": [e["photo"] for e in entries if str(e.get("photo") or "").startswith("/uploads/")]}


async def _ask_later() -> None:
    """Wait until the user stops adding for a bit, then hand all un-asked pending entries over at once."""
    try:
        await asyncio.sleep(ASK_DELAY_S)
    except asyncio.CancelledError:
        return
    pending = rows("WHERE status = 'pending' AND asked_at = ''")
    if not pending or not WEBHOOK:
        return
    headers = {"Authorization": f"Bearer {WEBHOOK_TOKEN}"} if WEBHOOK_TOKEN else {}
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            r = await client.post(WEBHOOK, json=pending_payload(pending), headers=headers)
        if r.status_code < 300:
            with db() as conn:
                conn.executemany("UPDATE food_entries SET asked_at = ? WHERE id = ?",
                                 [(now_iso(), e["id"]) for e in pending])
    except Exception as exc:
        print(f"[food] webhook failed: {exc}")


def schedule_ask() -> None:
    task = _ask.get("task")
    if task and not task.done():
        task.cancel()
    _ask["task"] = asyncio.create_task(_ask_later())


# ── endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"ok": True}


@app.get("/food/settings")
async def settings_get(request: Request):
    check_auth(request)
    s = load_settings()
    return {"settings": s, "targets": food_log.targets(s)}


@app.post("/food/settings")
async def settings_set(request: Request):
    check_auth(request)
    body = await request.json()
    s = load_settings()
    for k in ("mode", "activity", "sex"):
        if k in body:
            s[k] = str(body[k])
    for k in ("height_cm", "weight_kg", "age", "kcal", "protein"):
        if k in body and body[k] not in (None, ""):
            try:
                s[k] = float(body[k])
            except (TypeError, ValueError):
                raise HTTPException(status_code=400, detail=f"{k} must be a number")
    SETTINGS.write_text(json.dumps(s, ensure_ascii=False), "utf-8")
    return {"settings": s, "targets": food_log.targets(s)}


@app.get("/food/days")
async def days(request: Request, limit: int = 60, q: str = ""):
    """List page: one card per day (total, one-line summary per meal, first photo). q searches date or food."""
    check_auth(request)
    by_day: dict = {}
    for e in rows():
        by_day.setdefault(e["date"], []).append(e)
    tgt = food_log.targets(load_settings())
    out = []
    for date in sorted(by_day, reverse=True):
        entries = by_day[date]
        if q and q not in date and not any(q in e["text"] for e in entries):
            continue
        summ = food_log.summary(entries, tgt)
        out.append({"date": date, "kcal": summ["kcal"], "net": summ["net"], "pending": summ["pending"],
                    "blurb": food_log.day_blurb(entries, 80),
                    "photo": cover_for(date, entries)})
        if len(out) >= max(1, min(limit, 400)):
            break
    return {"days": out, "targets": tgt}


@app.post("/food/cover")
async def cover_set(request: Request):
    """{date, url}: make one of that day's photos the list-page cover. Empty url = back to the first photo."""
    check_auth(request)
    body = await request.json()
    date, url = str(body.get("date") or "")[:10], str(body.get("url") or "")
    if url and url not in [e["photo"] for e in rows("WHERE date = ?", (date,))]:
        raise HTTPException(status_code=400, detail="no such photo on that day")
    covers = load_covers()
    if url:
        covers[date] = url
    else:
        covers.pop(date, None)
    COVERS.write_text(json.dumps(covers, ensure_ascii=False), "utf-8")
    return day(date)


@app.get("/food/day/{date}")
async def day_get(request: Request, date: str):
    check_auth(request)
    return day(date)


@app.post("/food/entry")
async def entry_add(request: Request):
    """{meal, text, detail?, kcal?, protein?, carbs?, fat?, photo?, date?, source?}. No kcal = pending."""
    check_auth(request)
    body = await request.json()
    entry, err = food_log.clean_entry(body)
    if err:
        raise HTTPException(status_code=400, detail=err)
    date = str(body.get("date") or today())[:10]
    source = {"ai": "ai", "him": "ai", "watch": "watch"}.get(str(body.get("source") or ""), "user")
    # imported items (Apple Watch workouts) carry an ext_id: each one is logged once, deleted ones stay deleted
    ext_id = str(body.get("ext_id") or "").strip()[:80]
    if ext_id and (ext_id in deleted_ext() or rows("WHERE ext_id = ?", (ext_id,))):
        return {"id": None, "skipped": True, **day(date)}
    if source == "ai" and entry["status"] == "pending":
        raise HTTPException(status_code=400, detail="entries logged by the AI must include kcal")
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO food_entries (ts, date, meal, text, kcal, protein, carbs, fat, photo, source, status, "
            "detail, detail_est, portion, ext_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (now_iso(), date, entry["meal"], entry["text"], entry["kcal"], entry["protein"], entry["carbs"],
             entry["fat"], entry["photo"], source, entry["status"], entry["detail"], entry["detail_est"],
             entry["portion"], ext_id))
        new_id = cur.lastrowid
    if entry["status"] == "pending":
        schedule_ask()
    return {"id": new_id, **day(date)}


@app.patch("/food/entry/{entry_id}")
async def entry_edit(request: Request, entry_id: int):
    """Edit an entry, or fill in an estimate (sending kcal marks it done). by="ai" for the AI's estimate."""
    check_auth(request)
    body = await request.json()
    found = rows("WHERE id = ?", (entry_id,))
    if not found:
        raise HTTPException(status_code=404, detail="no such entry")
    cur = found[0]
    merged, err = food_log.clean_entry({**cur, **{k: v for k, v in body.items() if k != "id"}})
    if err:
        raise HTTPException(status_code=400, detail=err)
    by_ai = body.get("by") in ("ai", "him")
    # the AI's gram-by-gram detail goes to detail_est; the user's own words stay untouched
    if by_ai and "detail" in body:
        merged["detail_est"] = str(body.get("detail") or "").strip()[:400]
        merged["detail"] = cur.get("detail") or ""
    text_changed = ((merged["text"] != cur["text"] or merged["detail"] != (cur.get("detail") or ""))
                    and "kcal" not in body)
    if text_changed:       # the food changed but no new numbers → back to pending
        for k in ("kcal", "protein", "carbs", "fat"):
            merged[k] = None
        merged["detail_est"] = ""
        merged["status"] = "pending"
    with db() as conn:
        conn.execute(
            "UPDATE food_entries SET meal=?, text=?, kcal=?, protein=?, carbs=?, fat=?, photo=?, status=?, "
            "asked_at=?, detail=?, detail_est=?, portion=? WHERE id=?",
            (merged["meal"], merged["text"], merged["kcal"], merged["protein"], merged["carbs"], merged["fat"],
             merged["photo"], merged["status"], "" if text_changed else cur["asked_at"],
             merged["detail"], merged["detail_est"], merged["portion"], entry_id))
    if merged["status"] == "pending":
        schedule_ask()
    return day(cur["date"])


@app.delete("/food/entry/{entry_id}")
async def entry_delete(request: Request, entry_id: int):
    check_auth(request)
    found = rows("WHERE id = ?", (entry_id,))
    if not found:
        raise HTTPException(status_code=404, detail="no such entry")
    with db() as conn:
        conn.execute("DELETE FROM food_entries WHERE id = ?", (entry_id,))
    if found[0].get("ext_id"):
        DELETED_EXT.write_text(json.dumps(sorted(deleted_ext() | {found[0]["ext_id"]})), "utf-8")
    return day(found[0]["date"])


@app.get("/food/pending")
async def pending(request: Request):
    """For AIs that poll instead of receiving the webhook: everything still waiting for numbers."""
    check_auth(request)
    return pending_payload(rows("WHERE status = 'pending'"))


@app.post("/food/upload")
async def upload(request: Request, name: str = "photo.jpg"):
    """Raw image bytes in the body → {"url": "/uploads/<file>"}."""
    check_auth(request)
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="empty file")
    if len(data) > 12 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="file too large")
    ext = Path(name).suffix.lower() if Path(name).suffix.lower() in (".jpg", ".jpeg", ".png", ".heic", ".webp") else ".jpg"
    fname = f"{int(time.time())}-{secrets.token_hex(4)}{ext}"
    (UPLOADS / fname).write_bytes(data)
    return {"url": f"/uploads/{fname}"}


@app.get("/uploads/{fname}")
async def uploads(request: Request, fname: str, token: str = ""):
    """Photos. Web pages can't put a header on <img>, so ?token=... works here too (and only here)."""
    if not (TOKEN and token and secrets.compare_digest(token, TOKEN)):
        check_auth(request)
    path = (UPLOADS / fname).resolve()
    if path.parent != UPLOADS.resolve() or not path.exists():
        raise HTTPException(status_code=404, detail="not found")
    return FileResponse(path)


@app.get("/food/barcode/{code}")
async def barcode(request: Request, code: str):
    """Look one product up by barcode on Open Food Facts: per-100g and per-serving numbers."""
    check_auth(request)
    code = "".join(ch for ch in code if ch.isdigit())[:14]
    if len(code) < 8:
        raise HTTPException(status_code=400, detail="bad barcode")
    fields = "product_name,brands,nutriments,serving_size"
    for _ in range(2):
        try:
            async with httpx.AsyncClient(timeout=12, headers=UA) as client:
                r = await client.get(f"https://world.openfoodfacts.org/api/v2/product/{code}.json",
                                     params={"fields": fields})
            if r.status_code == 404:
                break
            if r.status_code != 200:
                await asyncio.sleep(1)
                continue
            d = r.json()
            found = food_log.off_products({"products": [d.get("product") or {}]}) if d.get("status") == 1 else []
            return {"found": bool(found), "product": found[0] if found else None, "code": code}
        except Exception:
            await asyncio.sleep(1)
    return {"found": False, "product": None, "code": code}


@app.get("/food/lookup")
async def lookup(request: Request, q: str = "", country: str = "world", limit: int = 5):
    """Search Open Food Facts by name. country = a subdomain like "au", "uk", "fr", or "world".
    limit: how many products to return (1-20). The AI asks for a few; the app's search sheet asks for 12."""
    check_auth(request)
    q = q.strip()[:80]
    if not q:
        raise HTTPException(status_code=400, detail="what should I look up?")
    limit = max(1, min(20, limit))
    country = "".join(ch for ch in country.lower() if ch.isalpha())[:8] or "world"
    params = {"search_terms": q, "search_simple": 1, "json": 1, "page_size": max(12, limit * 2),
              "fields": "product_name,brands,nutriments,serving_size"}
    hosts = [f"{country}.openfoodfacts.org"] + (["world.openfoodfacts.org"] if country != "world" else [])
    answered = False
    for host in hosts:
        found = []
        for attempt in range(2):   # Open Food Facts sometimes answers 503 under load; one retry is enough
            try:
                async with httpx.AsyncClient(timeout=12, headers=UA) as client:
                    r = await client.get(f"https://{host}/cgi/search.pl", params=params)
                if r.status_code != 200:
                    await asyncio.sleep(1)
                    continue
                found = food_log.off_products(r.json(), limit=limit)
                answered = True
                break
            except Exception:
                await asyncio.sleep(1)
        if found:
            return {"source": f"Open Food Facts ({host.split('.')[0]})", "products": found,
                    "lines": [food_log.off_line(p) for p in found]}
    if not answered:
        # every host failed: say so, instead of pretending nothing matched (the app would not retry)
        raise HTTPException(status_code=502, detail="Open Food Facts is not answering right now, try again in a moment")
    return {"source": "Open Food Facts", "products": [], "lines": []}
