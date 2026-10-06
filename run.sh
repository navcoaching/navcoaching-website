#!/usr/bin/env bash
# Start Nav Coaching on http://127.0.0.1:8000
set -e
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  python3 -m venv .venv
  .venv/bin/pip install -q -r requirements.txt
fi
exec .venv/bin/python -m navcoach.main
