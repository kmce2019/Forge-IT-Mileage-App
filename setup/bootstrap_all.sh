#!/usr/bin/env bash
set -euo pipefail
# Optional envs you might pass in:
# STACK_DIR API_HOST_PORT API_TOKEN LOCAL_TZ CAL_ICAL_URL KEYWORDS_REGEX EXCLUDE_REGEX
# SEND_WEEKDAY SEND_HOUR SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS MAIL_FROM MAIL_TO SUBJECT_PREFIX
# SYNC_INTERVAL_SEC WINDOW_DAYS
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/setup_api.sh"
bash "$SCRIPT_DIR/setup_jobsync.sh"
bash "$SCRIPT_DIR/setup_exporter.sh"
echo
echo "[*] Next:"
echo "  1) cd /opt/fn-mileage/server   && sudo docker compose up -d --build && sudo docker logs -f mileage_api"
echo "  2) cd /opt/fn-mileage/jobsync  && sudo docker compose up -d --build && sudo docker logs -f fn_jobsync"
echo "  3) cd /opt/fn-mileage/exporter && sudo docker compose up -d --build && sudo docker logs -f fn_weekly_exporter"
