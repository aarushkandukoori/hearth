#!/bin/bash
# Typecheck the app shell + all services + one or more UI areas (Simulator SDK).
# Usage: ios/scripts/typecheck-ui.sh UI/Chat [UI/Home ...]
set -euo pipefail
cd "$(dirname "$0")"
exec ./typecheck.sh App/AppModel.swift App/Navigation.swift Engine Brain Store Media UI/Theme Dev "$@"
