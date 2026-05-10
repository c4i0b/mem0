#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/server"
podman-compose down
