#!/usr/bin/env bash
set -euo pipefail

docker exec weekly-backup /usr/local/bin/backup once
