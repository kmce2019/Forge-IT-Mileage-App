#!/usr/bin/env bash
set -euo pipefail

# ===== Defaults (override via env) =====
STACK_DIR="${STACK_DIR:-/opt/fn-mileage}"
EXPORTER_DIR="${EXPORTER_DIR:-$STACK_DIR/exporter}"
LOCAL_TZ="${LOCAL_TZ:-America/Chicago}"
SEND_WEEKDAY="${SEND_WEEKDAY:-6}"
SEND_HOUR="${SEND_HOUR:-8}"
SUBJECT_PREFIX="${SUBJECT_PREFIX:-weekly mileage log}"
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
MAIL_FROM="${MAIL_FROM:-$SMTP_USER}"
MAIL_TO="${MAIL_TO:-}"

mkdir -p "$EXPORTER_DIR/out"
cat > "$EXPORTER_DIR/exporter.py" <<'PY'
import os, sqlite3, csv, smtplib, ssl, time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication
TZ = ZoneInfo(os.getenv("LOCAL_TZ", "America/Chicago"))
SEND_WEEKDAY = int(os.getenv("SEND_WEEKDAY", "6"))
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
    monday_this = (now_local - timedelta(days=(now_local.isoweekday()-1))).replace(hour=0, minute=0, second=0, microsecond=0)
    start_local = monday_this if now_local.isoweekday() >= 6 else monday_this - timedelta(days=7)
    end_local = (start_local + timedelta(days=5)) - timedelta(microseconds=1)
    return start_local, end_local
def export_csv(start_local: datetime, end_local: datetime) -> str:
    start_utc = start_local.astimezone(timezone.utc).isoformat()
    end_utc = end_local.astimezone(timezone.utc).isoformat()
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"mileage_{start_local.date()}_to_{end_local.date()}.csv")
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row; cur = conn.cursor()
    rows = cur.execute("SELECT * FROM trips WHERE start_ts >= ? AND end_ts <= ? ORDER BY start_ts ASC",(start_utc, end_utc)).fetchall()
    conn.close()
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["Date","Start Time","End Time","Miles","Duration (min)","Job Label","Notes"])
        for r in rows:
            st = datetime.fromisoformat(r["start_ts"].replace("Z","+00:00")).astimezone(TZ)
            et = datetime.fromisoformat(r["end_ts"].replace("Z","+00:00")).astimezone(TZ)
            w.writerow([st.date().isoformat(), st.strftime("%H:%M"), et.strftime("%H:%M"),
                        f"{float(r['miles']):.2f}", round(int(r["duration_sec"])/60),
                        r["job_label_cache"] or "", (r["notes"] or "").replace("\n"," ").strip()])
    return path
def send_email(attachment_path: str, start_local: datetime, end_local: datetime):
    if not (SMTP_HOST and SMTP_PORT and SMTP_USER and SMTP_PASS and MAIL_FROM and MAIL_TO):
        print("[weekly_exporter] Email not configured; saved CSV only."); return
    subject = f"{SUBJECT_PREFIX} {start_local.date()} to {end_local.date()}"
    body = f"Attached: mileage export for {start_local.date()} through {end_local.date()} (Mon–Fri)."
    msg = MIMEMultipart(); msg["From"]=MAIL_FROM; msg["To"]=", ".join(MAIL_TO); msg["Subject"]=subject
    msg.attach(MIMEText(body, "plain"))
    with open(attachment_path, "rb") as f:
        part = MIMEApplication(f.read(), Name=os.path.basename(attachment_path))
    part["Content-Disposition"] = f'attachment; filename="{os.path.basename(attachment_path)}"'
    msg.attach(part)
    context = ssl.create_default_context()
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
        server.starttls(context=context); server.login(SMTP_USER, SMTP_PASS); server.send_message(msg)
def should_fire(now_local: datetime) -> bool:
    return (now_local.isoweekday() == SEND_WEEKDAY) and (now_local.hour == SEND_HOUR)
def main_loop():
    print(f"[weekly_exporter] started. TZ={TZ}, schedule: weekday={SEND_WEEKDAY}, hour={SEND_HOUR}")
    fired_tag=None
    while True:
        now_local = datetime.now(TZ)
        tag=(now_local.isocalendar().year, now_local.isocalendar().week, now_local.hour)
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
if __name__ == "__main__": main_loop()
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

echo "[*] Weekly Exporter ready at: $EXPORTER_DIR"
echo "Run:  cd $EXPORTER_DIR && docker compose up -d --build && docker logs -f fn_weekly_exporter"
