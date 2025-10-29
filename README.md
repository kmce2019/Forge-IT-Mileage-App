# Forge-IT-Mileage-App

This sets up three services under /opt/fn-mileage:

## Mileage API (FastAPI + SQLite) — stores jobs and trips

## Calendar Job Sync — pulls a Field Nation ICS feed → posts jobs to API

##  Weekly Exporter — exports Mon–Fri trips to CSV, optional email

All run in Docker. Data is persisted on the host so you can rebuild containers without losing history.

## 0) Requirements

Ubuntu/Debian/Alpine host with Docker + Docker Compose v2

A domain (optional) if you host API behind HTTPS (you can start on plain http://HOST:8088)

Your Field Nation ICS URL

An API token you choose (shared between API and JobSync)

## 1) Bootstrap everything (single script)

This creates all folders, code, Dockerfiles, compose files, and sensible defaults.

Paste the whole block:
```
sudo tee /usr/local/bin/bootstrap_mileage_stack.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

# ===================== EDIT THESE DEFAULTS =====================
STACK_DIR="${STACK_DIR:-/opt/fn-mileage}"

# API — token must match what JobSync uses
API_HOST_PORT="${API_HOST_PORT:-8088}"
API_TOKEN="${API_TOKEN:-change-me-super-secret}"

# Your local timezone (affects Weekly Exporter)
LOCAL_TZ="${LOCAL_TZ:-America/Chicago}"

# Field Nation ICS URL (Calendar Job Sync)
CAL_ICAL_URL="${CAL_ICAL_URL:-https://app.fieldnation.com/marketplace/calendar.php?id=REPLACE_ME}"

# Regex that decides which events become jobs.
# Default = include all; also supports an exclusion list below.
KEYWORDS_REGEX="${KEYWORDS_REGEX:-.}"
EXCLUDE_REGEX="${EXCLUDE_REGEX:-Availability|PTO|Tentative|Reminder|Hold}"

# Weekly Exporter schedule (local time): Saturday 08:00
SEND_WEEKDAY="${SEND_WEEKDAY:-6}"   # ISO: Mon=1 .. Sun=7
SEND_HOUR="${SEND_HOUR:-8}"         # 0..23
# SMTP (leave blank to disable email; CSV still written)
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"           # e.g. forgeitservices@gmail.com
SMTP_PASS="${SMTP_PASS:-}"           # App Password if using Gmail
MAIL_FROM="${MAIL_FROM:-$SMTP_USER}"
MAIL_TO="${MAIL_TO:-}"               # comma-separated list
SUBJECT_PREFIX="${SUBJECT_PREFIX:-weekly mileage log}"

# How often the JobSync checks (seconds) and date window (days)
SYNC_INTERVAL_SEC="${SYNC_INTERVAL_SEC:-600}"
WINDOW_DAYS="${WINDOW_DAYS:-14}"
# ===============================================================

# Create stack root
sudo mkdir -p "$STACK_DIR"
sudo chown -R "$USER":"$USER" "$STACK_DIR"

# ==================== 1) Mileage API ====================
API_DIR="$STACK_DIR/server"
mkdir -p "$API_DIR/data"

cat > "$API_DIR/server.py" <<'PY'
import os, sqlite3, uvicorn
from fastapi import FastAPI, Depends, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from typing import Optional, List, Any
from datetime import datetime, timezone

DB_PATH = os.getenv("DB_PATH", "/data/mileage.db")
API_TOKEN = os.getenv("API_TOKEN", "change-me-super-secret")

app = FastAPI(title="Mileage API", version="1.0.0")

# Basic CORS (adjust if front-end is deployed)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

auth_scheme = HTTPBearer(auto_error=False)

def require_auth(creds: Optional[HTTPAuthorizationCredentials] = Depends(auth_scheme)):
    if not creds or creds.scheme.lower() != "bearer" or creds.credentials != API_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return True

def db():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = db()
    cur = conn.cursor()
    cur.executescript("""
    PRAGMA journal_mode=WAL;

    CREATE TABLE IF NOT EXISTS jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        label TEXT NOT NULL,
        client TEXT,
        wo_number TEXT,
        start_window_ts TEXT,
        end_window_ts TEXT,
        created_ts TEXT NOT NULL DEFAULT (datetime('now')),
        updated_ts TEXT NOT NULL DEFAULT (datetime('now'))
    );

    -- Upsert "uniqueness": label+start_window_ts often sufficient for FN
    CREATE UNIQUE INDEX IF NOT EXISTS jobs_label_start_ux
      ON jobs (label, start_window_ts);

    CREATE TABLE IF NOT EXISTS trips (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_ts TEXT NOT NULL,            -- UTC ISO string
        end_ts   TEXT NOT NULL,            -- UTC ISO string
        miles    REAL NOT NULL DEFAULT 0,
        duration_sec INTEGER NOT NULL DEFAULT 0,
        job_id   INTEGER,
        job_label_cache TEXT,
        notes    TEXT,
        created_ts TEXT NOT NULL DEFAULT (datetime('now')),
        updated_ts TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY(job_id) REFERENCES jobs(id)
    );

    CREATE INDEX IF NOT EXISTS trips_time_idx ON trips (start_ts, end_ts);
    """)
    conn.commit()
    conn.close()

init_db()

class JobIn(BaseModel):
    label: str
    client: Optional[str] = None
    wo_number: Optional[str] = None
    start_window_ts: Optional[str] = None
    end_window_ts: Optional[str] = None

class TripIn(BaseModel):
    start_ts: str          # UTC ISO
    end_ts: str            # UTC ISO
    miles: float
    duration_sec: int
    job_id: Optional[int] = None
    job_label_cache: Optional[str] = None
    notes: Optional[str] = None

@app.get("/health")
def health():
    return {"ok": True}

@app.get("/jobs", dependencies=[Depends(require_auth)])
def list_jobs(limit: int = 200, offset: int = 0):
    conn = db(); cur = conn.cursor()
    rows = cur.execute(
        "SELECT * FROM jobs ORDER BY created_ts DESC LIMIT ? OFFSET ?",
        (limit, offset)
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]

@app.post("/jobs", dependencies=[Depends(require_auth)])
def upsert_job(payload: JobIn):
    # Upsert by (label, start_window_ts)
    conn = db(); cur = conn.cursor()
    try:
        cur.execute("""
            INSERT INTO jobs (label, client, wo_number, start_window_ts, end_window_ts)
            VALUES (?,?,?,?,?)
            ON CONFLICT(label, start_window_ts) DO UPDATE SET
                client=excluded.client,
                wo_number=excluded.wo_number,
                end_window_ts=excluded.end_window_ts,
                updated_ts=datetime('now')
        """, (payload.label, payload.client, payload.wo_number,
              payload.start_window_ts, payload.end_window_ts))
        conn.commit()
        # Return the upserted row
        row = cur.execute(
            "SELECT * FROM jobs WHERE label=? AND (start_window_ts IS ? OR start_window_ts=?)",
            (payload.label, payload.start_window_ts, payload.start_window_ts)
        ).fetchone()
        return dict(row)
    finally:
        conn.close()

@app.post("/trips", dependencies=[Depends(require_auth)])
def create_trip(payload: TripIn):
    conn = db(); cur = conn.cursor()
    try:
        cur.execute("""
            INSERT INTO trips (start_ts, end_ts, miles, duration_sec, job_id, job_label_cache, notes)
            VALUES (?,?,?,?,?,?,?)
        """, (payload.start_ts, payload.end_ts, float(payload.miles), int(payload.duration_sec),
              payload.job_id, payload.job_label_cache, payload.notes))
        conn.commit()
        trip_id = cur.lastrowid
        row = cur.execute("SELECT * FROM trips WHERE id=?", (trip_id,)).fetchone()
        return dict(row)
    finally:
        conn.close()

@app.get("/trips", dependencies=[Depends(require_auth)])
def list_trips(limit: int = 200, offset: int = 0):
    conn = db(); cur = conn.cursor()
    rows = cur.execute(
        "SELECT * FROM trips ORDER BY start_ts DESC LIMIT ? OFFSET ?",
        (limit, offset)
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]

if __name__ == "__main__":
    uvicorn.run("server:app", host="0.0.0.0", port=int(os.getenv("PORT","8088")))
PY

cat > "$API_DIR/Dockerfile" <<'DOCKER'
FROM python:3.12-alpine
WORKDIR /app
COPY server.py /app/server.py
RUN pip install --no-cache-dir fastapi uvicorn[standard]
ENV PYTHONUNBUFFERED=1
EXPOSE 8088
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8088"]
DOCKER

cat > "$API_DIR/.env" <<ENV
API_TOKEN="${API_TOKEN}"
DB_PATH="/data/mileage.db"
ENV

cat > "$API_DIR/docker-compose.yml" <<EOF
services:
  mileage_api:
    build: .
    image: mileage-api:latest
    container_name: mileage_api
    env_file: .env
    environment:
      - API_TOKEN=\${API_TOKEN}
      - DB_PATH=/data/mileage.db
    volumes:
      - ./data:/data
    ports:
      - "${API_HOST_PORT}:8088"
    restart: unless-stopped
EOF

# ==================== 2) Calendar Job Sync ====================
JOBSYNC_DIR="$STACK_DIR/jobsync"
mkdir -p "$JOBSYNC_DIR"

cat > "$JOBSYNC_DIR/sync.py" <<'PY'
import os, re, time, requests, sys
from datetime import datetime, timezone, timedelta
from dateutil import parser as dtp

CAL_ICAL_URL  = os.getenv("CAL_ICAL_URL")
API_BASE      = os.getenv("API_BASE", "http://localhost:8088")
API_TOKEN     = os.getenv("API_TOKEN", "")
KEYWORDS_RE   = os.getenv("KEYWORDS_REGEX", ".")
EXCLUDE_RE    = os.getenv("EXCLUDE_REGEX", "")
INTERVAL      = int((os.getenv("SYNC_INTERVAL_SEC") or "600"))
WINDOW_DAYS   = int((os.getenv("WINDOW_DAYS") or "14"))

KW = re.compile(KEYWORDS_RE, re.IGNORECASE)
EXCL = re.compile(EXCLUDE_RE, re.IGNORECASE) if EXCLUDE_RE else None

def parse_ics(text: str):
    events, cur, in_evt = [], {}, False
    lines = text.splitlines()
    unfolded = []
    for line in lines:
        if line.startswith((" ", "\t")) and unfolded:
            unfolded[-1] += line[1:]
        else:
            unfolded.append(line)
    for line in unfolded:
        if line.startswith("BEGIN:VEVENT"):
            cur = {}; in_evt = True
        elif line.startswith("END:VEVENT"):
            if in_evt and ("SUMMARY" in cur or "DESCRIPTION" in cur):
                events.append(cur)
            in_evt = False
        elif in_evt and ":" in line:
            k, v = line.split(":", 1)
            k = k.split(";", 1)[0].strip().upper()
            cur[k] = v.strip()
    return events

def to_utc_iso(dt_val: str):
    dt = dtp.parse(dt_val)
    if not dt.tzinfo:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat()

def extract_client_and_wo(summary: str):
    wo = None
    m = re.search(r'(WO[#:\s\-]?)(\d{5,})', summary or "", re.IGNORECASE)
    if m: wo = m.group(2)
    if not summary: return "", wo
    if " – " in summary:
        client = summary.split(" – ", 1)[0].strip()
    elif " - " in summary:
        client = summary.split(" - ", 1)[0].strip()
    else:
        client = summary.strip()
    return client, wo

def upsert_job(job):
    try:
        r = requests.post(
            f"{API_BASE}/jobs",
            headers={"Authorization": f"Bearer {API_TOKEN}", "Content-Type":"application/json"},
            json=job, timeout=30
        )
        if r.status_code not in (200,201):
            print("[jobsync] POST /jobs failed:", r.status_code, r.text, file=sys.stderr)
        else:
            print("[jobsync] posted:", job.get("label","")[:120])
    except Exception as e:
        print("[jobsync] POST error:", e, file=sys.stderr)

def run_once():
    if not CAL_ICAL_URL:
        print("[jobsync] CAL_ICAL_URL missing"); return
    try:
        resp = requests.get(CAL_ICAL_URL, timeout=30, headers={"User-Agent":"fn-jobsync/1.0"})
        print("[jobsync] GET", resp.status_code, "len=", len(resp.text))
        ics = resp.text
    except Exception as e:
        print("[jobsync] fetch ICS failed:", e, file=sys.stderr); return

    events = parse_ics(ics)
    print("[jobsync] parsed events:", len(events))

    now = datetime.now(timezone.utc)
    lo = now - timedelta(days=WINDOW_DAYS)
    hi = now + timedelta(days=WINDOW_DAYS)
    filtered = []
    for e in events:
        dts = e.get("DTSTART") or e.get("DTSTART;TZID") or e.get("DTSTART;VALUE=DATE")
        if not dts:
            continue
        try:
            st = dtp.parse(dts)
            if not st.tzinfo: st = st.replace(tzinfo=timezone.utc)
        except Exception:
            continue
        if lo <= st <= hi:
            filtered.append(e)

    print("[jobsync] windowed events:", len(filtered))

    for e in filtered:
        summary = e.get("SUMMARY","").strip()
        description = e.get("DESCRIPTION","").strip()
        haystack = (summary + " " + description).strip()
        if not haystack:
            continue

        if EXCL and EXCL.search(haystack):
            continue

        if not KW.search(haystack):
            continue

        print("[jobsync] candidate:", summary[:200] if summary else "(no title)")

        dt_start = e.get("DTSTART") or e.get("DTSTART;TZID") or e.get("DTSTART;VALUE=DATE")
        dt_end   = e.get("DTEND") or e.get("DTEND;TZID") or e.get("DTEND;VALUE=DATE")
        try:
            start_iso = to_utc_iso(dt_start) if dt_start else None
            end_iso   = to_utc_iso(dt_end) if dt_end else start_iso
        except Exception:
            continue

        client, wo = extract_client_and_wo(summary or description)
        job = {
            "label": summary or description[:120],
            "client": client,
            "wo_number": wo,
            "start_window_ts": start_iso,
            "end_window_ts": end_iso
        }
        upsert_job(job)

if __name__ == "__main__":
    print("[jobsync] starting loop; interval:", os.getenv("SYNC_INTERVAL_SEC","600"), "sec; window ±", os.getenv("WINDOW_DAYS","14"), "days; regex:", os.getenv("KEYWORDS_REGEX","."))
    while True:
        try:
            run_once()
        except Exception as e:
            print("[jobsync] error:", e, file=sys.stderr)
        time.sleep(INTERVAL)
PY

cat > "$JOBSYNC_DIR/Dockerfile" <<'DOCKER'
FROM python:3.12-alpine
WORKDIR /app
COPY sync.py .
RUN pip install --no-cache-dir python-dateutil requests
ENV PYTHONUNBUFFERED=1
CMD ["python","sync.py"]
DOCKER

cat > "$JOBSYNC_DIR/.env" <<ENV
# Where to fetch ICS and where to post jobs
CAL_ICAL_URL="${CAL_ICAL_URL}"
API_BASE="http://host.docker.internal:${API_HOST_PORT}"
API_TOKEN="${API_TOKEN}"

# Include / exclude logic
KEYWORDS_REGEX="${KEYWORDS_REGEX}"
EXCLUDE_REGEX="${EXCLUDE_REGEX}"

# Frequency & window
SYNC_INTERVAL_SEC="${SYNC_INTERVAL_SEC}"
WINDOW_DAYS="${WINDOW_DAYS}"
ENV

cat > "$JOBSYNC_DIR/docker-compose.yml" <<'EOF'
services:
  jobsync:
    build: .
    image: fn-jobsync:latest
    container_name: fn_jobsync
    env_file: .env
    restart: unless-stopped
EOF

# ==================== 3) Weekly Exporter ====================
EXPORTER_DIR="$STACK_DIR/exporter"
mkdir -p "$EXPORTER_DIR/out"

cat > "$EXPORTER_DIR/exporter.py" <<'PY'
import os, sqlite3, csv, smtplib, ssl, time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication

TZ = ZoneInfo(os.getenv("LOCAL_TZ", "America/Chicago"))
SEND_WEEKDAY = int(os.getenv("SEND_WEEKDAY", "6"))   # Sat
SEND_HOUR = int(os.getenv("SEND_HOUR", "8"))
DB_PATH = os.getenv("DB_PATH", "/data/mileage.db")
OUT_DIR = os.getenv("OUT_DIR", "/out")

SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
MAIL_FROM = os.getenv("MAIL_FROM", SMTP_USER or "")
MAIL_TO = [x.strip() for x in os.getenv("MAIL_TO", "").split(",") if x.strip()]
SUBJECT_PREFIX = os.getenv("SUBJECT_PREFIX", "weekly mileage log")
SLEEP_SECONDS = int(os.getenv("SLEEP_SECONDS", "300"))

def last_completed_mon_fri(now_local: datetime):
    monday_this = (now_local - timedelta(days=(now_local.isoweekday()-1))).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    if now_local.isoweekday() >= 6:
        start_local = monday_this
    else:
        start_local = monday_this - timedelta(days=7)
    end_local = (start_local + timedelta(days=5)) - timedelta(microseconds=1)
    return start_local, end_local

def export_csv(start_local: datetime, end_local: datetime) -> str:
    start_utc = start_local.astimezone(timezone.utc).isoformat()
    end_utc = end_local.astimezone(timezone.utc).isoformat()

    os.makedirs(OUT_DIR, exist_ok=True)
    fname = f"mileage_{start_local.date()}_to_{end_local.date()}.csv"
    path = os.path.join(OUT_DIR, fname)

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    rows = cur.execute(
        "SELECT * FROM trips WHERE start_ts >= ? AND end_ts <= ? ORDER BY start_ts ASC",
        (start_utc, end_utc)
    ).fetchall()
    conn.close()

    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["Date","Start Time","End Time","Miles","Duration (min)","Job Label","Notes"])
        for r in rows:
            st = datetime.fromisoformat(r["start_ts"].replace("Z","+00:00")).astimezone(TZ)
            et = datetime.fromisoformat(r["end_ts"].replace("Z","+00:00")).astimezone(TZ)
            w.writerow([
                st.date().isoformat(),
                st.strftime("%H:%M"),
                et.strftime("%H:%M"),
                f"{float(r['miles']):.2f}",
                round(int(r["duration_sec"])/60),
                r["job_label_cache"] or "",
                (r["notes"] or "").replace("\n"," ").strip()
            ])
    return path

def send_email(attachment_path: str, start_local: datetime, end_local: datetime):
    if not (SMTP_HOST and SMTP_PORT and SMTP_USER and SMTP_PASS and MAIL_FROM and MAIL_TO):
        print("[weekly_exporter] Email not configured; saved CSV only.")
        return
    subject = f"{SUBJECT_PREFIX} {start_local.date()} to {end_local.date()}"
    body = f"Attached: mileage export for {start_local.date()} through {end_local.date()} (Mon–Fri)."

    msg = MIMEMultipart()
    msg["From"] = MAIL_FROM
    msg["To"] = ", ".join(MAIL_TO)
    msg["Subject"] = subject

    msg.attach(MIMEText(body, "plain"))
    with open(attachment_path, "rb") as f:
        part = MIMEApplication(f.read(), Name=os.path.basename(attachment_path))
    part["Content-Disposition"] = f'attachment; filename="{os.path.basename(attachment_path)}"'
    msg.attach(part)

    context = ssl.create_default_context()
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
        server.starttls(context=context)
        server.login(SMTP_USER, SMTP_PASS)
        server.send_message(msg)

def should_fire(now_local: datetime) -> bool:
    return (now_local.isoweekday() == SEND_WEEKDAY) and (now_local.hour == SEND_HOUR)

def main_loop():
    print(f"[weekly_exporter] started. TZ={TZ}, schedule: weekday={SEND_WEEKDAY}, hour={SEND_HOUR}")
    fired_tag = None
    while True:
        now_local = datetime.now(TZ)
        tag = (now_local.isocalendar().year, now_local.isocalendar().week, now_local.hour)
        if should_fire(now_local) and tag != fired_tag:
            start_local, end_local = last_completed_mon_fri(now_local)
            print(f"[weekly_exporter] exporting {start_local} -> {end_local}")
            try:
                csv_path = export_csv(start_local, end_local)
                print(f"[weekly_exporter] wrote {csv_path}")
                send_email(csv_path, start_local, end_local)
                print("[weekly_exporter] done.")
            except Exception as e:
                print("[weekly_exporter] ERROR:", e)
            fired_tag = tag
        time.sleep(int(os.getenv("SLEEP_SECONDS","300")))

if __name__ == "__main__":
    main_loop()
PY

cat > "$EXPORTER_DIR/Dockerfile" <<'DOCKER'
FROM python:3.12-alpine
WORKDIR /app
COPY exporter.py ./
RUN pip install --no-cache-dir tzdata
ENV PYTHONUNBUFFERED=1
CMD ["python", "exporter.py"]
DOCKER

cat > "$EXPORTER_DIR/docker-compose.yml" <<'EOF'
services:
  weekly_exporter:
    build: .
    image: fn-weekly-exporter:latest
    container_name: fn_weekly_exporter
    environment:
      - LOCAL_TZ=${LOCAL_TZ}
      - SEND_WEEKDAY=${SEND_WEEKDAY}
      - SEND_HOUR=${SEND_HOUR}
      - DB_PATH=/data/mileage.db
      - OUT_DIR=/out
      - SUBJECT_PREFIX=${SUBJECT_PREFIX}
      - SMTP_HOST=${SMTP_HOST}
      - SMTP_PORT=${SMTP_PORT}
      - SMTP_USER=${SMTP_USER}
      - SMTP_PASS=${SMTP_PASS}
      - MAIL_FROM=${MAIL_FROM}
      - MAIL_TO=${MAIL_TO}
      - SLEEP_SECONDS=300
    volumes:
      - ../server/data:/data:ro
      - ./out:/out
    restart: unless-stopped
EOF

# ==================== Done ====================
echo "[*] Stack created under: $STACK_DIR"
echo "[*] Next:"
echo "    1) cd $STACK_DIR/server   && docker compose up -d --build && docker logs -f mileage_api"
echo "    2) cd $STACK_DIR/jobsync  && docker compose up -d --build && docker logs -f fn_jobsync"
echo "    3) cd $STACK_DIR/exporter && docker compose up -d --build && docker logs -f fn_weekly_exporter"
BASH

sudo chmod +x /usr/local/bin/bootstrap_mileage_stack.sh
```

## Run It
```
# Optional: set your real values inline
sudo STACK_DIR=/opt/fn-mileage \
     API_TOKEN='your-super-token' \
     CAL_ICAL_URL='https://app.fieldnation.com/marketplace/calendar.php?id=Rk5fMTAzNDk4NF9DQUw=' \
     LOCAL_TZ='America/Chicago' \
     /usr/local/bin/bootstrap_mileage_stack.sh

```

Then bring up each service:
```
cd /opt/fn-mileage/server   && sudo docker compose up -d --build && sudo docker logs -f mileage_api
cd /opt/fn-mileage/jobsync  && sudo docker compose up -d --build && sudo docker logs -f fn_jobsync
cd /opt/fn-mileage/exporter && sudo docker compose up -d --build && sudo docker logs -f fn_weekly_exporter

```

## 2) How to run (common commands)

Check API health
```
curl -s http://localhost:8088/health | jq .
```

List jobs
```
curl -s http://localhost:8088/jobs \
  -H "Authorization: Bearer YOUR_TOKEN" | jq .
```

Post a trip (example)
```
curl -s -X POST http://localhost:8088/trips \
  -H "Authorization: Bearer YOUR_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "start_ts":"2025-10-20T13:00:00Z",
    "end_ts":"2025-10-20T13:45:00Z",
    "miles": 22.3,
    "duration_sec": 2700,
    "job_label_cache":"ACME – WO#123456",
    "notes":"Test trip"
  }' | jq .
```

Tail logs
```
docker logs -f mileage_api
docker logs -f fn_jobsync
docker logs -f fn_weekly_exporter
```

Restart any service
```
cd /opt/fn-mileage/<server|jobsync|exporter>
sudo docker compose up -d --build
```

## 3) File/Folder layout

/opt/fn-mileage
├── server
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── .env
│   ├── data/                 # <-- SQLite DB lives here (mileage.db)
│   └── server.py
├── jobsync
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── .env                  # CAL_ICAL_URL, API_BASE, API_TOKEN, regex, etc.
│   └── sync.py
└── exporter
    ├── Dockerfile
    ├── docker-compose.yml
    ├── out/                  # <-- Weekly CSV exports appear here
    └── exporter.py

## 4) Security & tokens

Bearer token protects /jobs and /trips.

Set the token once: API_TOKEN="..." in /opt/fn-mileage/server/.env (created by the bootstrap)

The same token must be in /opt/fn-mileage/jobsync/.env

Rotate token

Stop jobsync: cd /opt/fn-mileage/jobsync && docker compose down

Edit /opt/fn-mileage/server/.env and /opt/fn-mileage/jobsync/.env with the same new token

Restart API and jobsync:
```
cd /opt/fn-mileage/server && docker compose up -d
cd /opt/fn-mileage/jobsync && docker compose up -d
```

## 5) Backups & restore

Backup (DB + exported CSVs)
```
sudo tar -czf /root/mileage-backup-$(date +%F).tgz \
  -C /opt/fn-mileage/server data \
  -C /opt/fn-mileage/exporter out
```

Restore (on a new host)

```
sudo tar -xzf /root/mileage-backup-YYYY-MM-DD.tgz -C /
# If your stack dir differs, move the folders accordingly
```

## 6) Customizing JobSync matching

Include everything (safe if your ICS is FN-only):
```
sed -i 's/^KEYWORDS_REGEX=.*/KEYWORDS_REGEX="."/' /opt/fn-mileage/jobsync/.env
```

Exclude common noise:
```
sed -i 's/^EXCLUDE_REGEX=.*/EXCLUDE_REGEX="Availability|PTO|Tentative|Reminder|Hold"/' /opt/fn-mileage/jobsync/.env
```

Apply changes:
```
cd /opt/fn-mileage/jobsync && docker compose up -d && docker logs -f fn_jobsync
```

## 7) Troubleshooting

Compose warns envs are blank: Create or fix .env files, or export envs before docker compose up.

JobSync shows parsed events but no candidate: Relax KEYWORDS_REGEX="." then tighten later and/or use EXCLUDE_REGEX.

POST /jobs failed: 401: Tokens don’t match. Ensure /opt/fn-mileage/server/.env and /opt/fn-mileage/jobsync/.env use the same API_TOKEN.

Exporter emails not sending: leave SMTP blank to only write CSV. When ready, set SMTP_* and MAIL_* in exporter/docker-compose.yml (they’re already wired to envs).

## 8) Make scripts executable
```
sudo chmod +x /usr/local/bin/bootstrap_mileage_stack.sh
```

(Everything else runs via Docker Compose; no other scripts need execution bits.)





