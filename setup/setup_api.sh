#!/usr/bin/env bash
set -euo pipefail

# ===== Defaults (override via env) =====
STACK_DIR="${STACK_DIR:-/opt/fn-mileage}"
API_DIR="${API_DIR:-$STACK_DIR/server}"
API_HOST_PORT="${API_HOST_PORT:-8088}"
API_TOKEN="${API_TOKEN:-change-me-super-secret}"

mkdir -p "$API_DIR/data"
cat > "$API_DIR/server.py" <<'PY'
import os, sqlite3, uvicorn
from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from typing import Optional
DB_PATH = os.getenv("DB_PATH", "/data/mileage.db")
API_TOKEN = os.getenv("API_TOKEN", "change-me-super-secret")
app = FastAPI(title="Mileage API", version="1.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])
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
    conn = db(); cur = conn.cursor()
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
    CREATE UNIQUE INDEX IF NOT EXISTS jobs_label_start_ux ON jobs (label, start_window_ts);
    CREATE TABLE IF NOT EXISTS trips (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_ts TEXT NOT NULL,
        end_ts   TEXT NOT NULL,
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
    conn.commit(); conn.close()
init_db()
from pydantic import BaseModel
class JobIn(BaseModel):
    label: str
    client: Optional[str] = None
    wo_number: Optional[str] = None
    start_window_ts: Optional[str] = None
    end_window_ts: Optional[str] = None
class TripIn(BaseModel):
    start_ts: str
    end_ts: str
    miles: float
    duration_sec: int
    job_id: Optional[int] = None
    job_label_cache: Optional[str] = None
    notes: Optional[str] = None
@app.get("/health")
def health(): return {"ok": True}
@app.get("/jobs", dependencies=[Depends(require_auth)])
def list_jobs(limit: int = 200, offset: int = 0):
    conn = db(); rows = conn.execute("SELECT * FROM jobs ORDER BY created_ts DESC LIMIT ? OFFSET ?", (limit, offset)).fetchall(); conn.close()
    return [dict(r) for r in rows]
@app.post("/jobs", dependencies=[Depends(require_auth)])
def upsert_job(p: JobIn):
    conn = db(); cur = conn.cursor()
    cur.execute("""
        INSERT INTO jobs (label, client, wo_number, start_window_ts, end_window_ts)
        VALUES (?,?,?,?,?)
        ON CONFLICT(label, start_window_ts) DO UPDATE SET
            client=excluded.client,
            wo_number=excluded.wo_number,
            end_window_ts=excluded.end_window_ts,
            updated_ts=datetime('now')
    """, (p.label, p.client, p.wo_number, p.start_window_ts, p.end_window_ts))
    conn.commit()
    row = cur.execute("SELECT * FROM jobs WHERE label=? AND (start_window_ts IS ? OR start_window_ts=?)",
                      (p.label, p.start_window_ts, p.start_window_ts)).fetchone()
    conn.close(); return dict(row)
@app.post("/trips", dependencies=[Depends(require_auth)])
def create_trip(p: TripIn):
    conn = db(); cur = conn.cursor()
    cur.execute("""INSERT INTO trips (start_ts, end_ts, miles, duration_sec, job_id, job_label_cache, notes)
                   VALUES (?,?,?,?,?,?,?)""",
                (p.start_ts, p.end_ts, float(p.miles), int(p.duration_sec), p.job_id, p.job_label_cache, p.notes))
    conn.commit(); row = cur.execute("SELECT * FROM trips WHERE id=?", (cur.lastrowid,)).fetchone()
    conn.close(); return dict(row)
@app.get("/trips", dependencies=[Depends(require_auth)])
def list_trips(limit: int = 200, offset: int = 0):
    conn = db(); rows = conn.execute("SELECT * FROM trips ORDER BY start_ts DESC LIMIT ? OFFSET ?", (limit, offset)).fetchall(); conn.close()
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
    volumes:
      - ./data:/data
    ports:
      - "${API_HOST_PORT}:8088"
    restart: unless-stopped
EOF

echo "[*] API ready at: $API_DIR"
echo "Run:  cd $API_DIR && docker compose up -d --build && docker logs -f mileage_api"
