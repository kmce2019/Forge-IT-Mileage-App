#!/usr/bin/env bash
set -euo pipefail

# ===== Defaults (override via env) =====
STACK_DIR="${STACK_DIR:-/opt/fn-mileage}"
JOBSYNC_DIR="${JOBSYNC_DIR:-$STACK_DIR/jobsync}"
API_HOST_PORT="${API_HOST_PORT:-8088}"
CAL_ICAL_URL="${CAL_ICAL_URL:-https://app.fieldnation.com/marketplace/calendar.php?id=REPLACE_ME}"
API_TOKEN="${API_TOKEN:-change-me-super-secret}"
KEYWORDS_REGEX="${KEYWORDS_REGEX:-.}"
EXCLUDE_REGEX="${EXCLUDE_REGEX:-Availability|PTO|Tentative|Reminder|Hold}"
SYNC_INTERVAL_SEC="${SYNC_INTERVAL_SEC:-600}"
WINDOW_DAYS="${WINDOW_DAYS:-14}"

mkdir -p "$JOBSYNC_DIR"
cat > "$JOBSYNC_DIR/sync.py" <<'PY'
import os, re, time, requests, sys
from datetime import datetime, timezone, timedelta
from dateutil import parser as dtp
CAL_ICAL_URL  = os.getenv("CAL_ICAL_URL")
API_BASE      = os.getenv("API_BASE","http://host.docker.internal:8088")
API_TOKEN     = os.getenv("API_TOKEN","")
KEYWORDS_RE   = os.getenv("KEYWORDS_REGEX",".")
EXCLUDE_RE    = os.getenv("EXCLUDE_REGEX","")
INTERVAL      = int((os.getenv("SYNC_INTERVAL_SEC") or "600"))
WINDOW_DAYS   = int((os.getenv("WINDOW_DAYS") or "14"))
KW = re.compile(KEYWORDS_RE, re.IGNORECASE)
EXCL = re.compile(EXCLUDE_RE, re.IGNORECASE) if EXCLUDE_RE else None
def parse_ics(text: str):
    events, cur, in_evt = [], {}, False
    lines = text.splitlines(); unfolded=[]
    for line in lines:
        if line.startswith((" ","\t")) and unfolded: unfolded[-1]+=line[1:]
        else: unfolded.append(line)
    for line in unfolded:
        if line.startswith("BEGIN:VEVENT"): cur={}; in_evt=True
        elif line.startswith("END:VEVENT"):
            if in_evt and ("SUMMARY" in cur or "DESCRIPTION" in cur): events.append(cur)
            in_evt=False
        elif in_evt and ":" in line:
            k,v = line.split(":",1); k=k.split(";",1)[0].strip().upper(); cur[k]=v.strip()
    return events
def to_utc_iso(dt_val: str):
    dt = dtp.parse(dt_val)
    if not dt.tzinfo: dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat()
def extract_client_and_wo(summary: str):
    wo=None; m=re.search(r'(WO[#:\s\-]?)(\d{5,})', summary or "", re.IGNORECASE)
    if m: wo=m.group(2)
    if not summary: return "", wo
    if " – " in summary: client=summary.split(" – ",1)[0].strip()
    elif " - " in summary: client=summary.split(" - ",1)[0].strip()
    else: client=summary.strip()
    return client, wo
def upsert_job(job):
    try:
        r=requests.post(f"{API_BASE}/jobs", headers={"Authorization": f"Bearer {API_TOKEN}","Content-Type":"application/json"}, json=job, timeout=30)
        if r.status_code not in (200,201): print("[jobsync] POST /jobs failed:", r.status_code, r.text, file=sys.stderr)
        else: print("[jobsync] posted:", job.get("label","")[:120])
    except Exception as e: print("[jobsync] POST error:", e, file=sys.stderr)
def run_once():
    if not CAL_ICAL_URL: print("[jobsync] CAL_ICAL_URL missing"); return
    try:
        resp=requests.get(CAL_ICAL_URL, timeout=30, headers={"User-Agent":"fn-jobsync/1.0"})
        print("[jobsync] GET", resp.status_code, "len=", len(resp.text)); ics=resp.text
    except Exception as e: print("[jobsync] fetch ICS failed:", e, file=sys.stderr); return
    events=parse_ics(ics); print("[jobsync] parsed events:", len(events))
    now=datetime.now(timezone.utc); lo=now-timedelta(days=WINDOW_DAYS); hi=now+timedelta(days=WINDOW_DAYS)
    filtered=[]
    for e in events:
        dts=e.get("DTSTART") or e.get("DTSTART;TZID") or e.get("DTSTART;VALUE=DATE")
        if not dts: continue
        try:
            st=dtp.parse(dts);  st=st if st.tzinfo else st.replace(tzinfo=timezone.utc)
        except Exception: continue
        if lo <= st <= hi: filtered.append(e)
    print("[jobsync] windowed events:", len(filtered))
    for e in filtered:
        summary=e.get("SUMMARY","").strip(); description=e.get("DESCRIPTION","").strip()
        haystack=(summary+" "+description).strip()
        if not haystack: continue
        if EXCL and EXCL.search(haystack): continue
        if not KW.search(haystack): continue
        print("[jobsync] candidate:", summary[:200] if summary else "(no title)")
        dt_start=e.get("DTSTART") or e.get("DTSTART;TZID") or e.get("DTSTART;VALUE=DATE")
        dt_end  =e.get("DTEND")   or e.get("DTEND;TZID")   or e.get("DTEND;VALUE=DATE")
        try:
            start_iso=to_utc_iso(dt_start) if dt_start else None
            end_iso  =to_utc_iso(dt_end) if dt_end else start_iso
        except Exception: continue
        client, wo=extract_client_and_wo(summary or description)
        job={"label": summary or description[:120], "client": client, "wo_number": wo, "start_window_ts": start_iso, "end_window_ts": end_iso}
        upsert_job(job)
if __name__=="__main__":
    print("[jobsync] starting loop; interval:", os.getenv("SYNC_INTERVAL_SEC","600"), "sec; window ±", os.getenv("WINDOW_DAYS","14"), "days; regex:", os.getenv("KEYWORDS_REGEX","."))
    while True:
        try: run_once()
        except Exception as e: print("[jobsync] error:", e, file=sys.stderr)
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
CAL_ICAL_URL="${CAL_ICAL_URL}"
API_BASE="http://host.docker.internal:${API_HOST_PORT}"
API_TOKEN="${API_TOKEN}"
KEYWORDS_REGEX="${KEYWORDS_REGEX}"
EXCLUDE_REGEX="${EXCLUDE_REGEX}"
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

echo "[*] JobSync ready at: $JOBSYNC_DIR"
echo "Run:  cd $JOBSYNC_DIR && docker compose up -d --build && docker logs -f fn_jobsync"
