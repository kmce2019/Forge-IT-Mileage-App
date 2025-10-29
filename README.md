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
