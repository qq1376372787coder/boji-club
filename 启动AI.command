#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/backend"
python3 setup.py
python3 server.py
