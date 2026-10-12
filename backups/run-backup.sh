#!/usr/bin/env bash
set -euo pipefail

docker exec backup /usr/local/bin/backup once
