#!/bin/bash
# Typecheck the app shell + all services + one or more UI areas (Simulator SDK). See typecheck.sh.
# Usage: ios/scripts/typecheck-ui.sh UI/Chat UI/Settings [UI/Home ...]  (UI areas use each other's types)
#        ios/scripts/typecheck-ui.sh UI App                            (the whole app)
set -euo pipefail
cd "$(dirname "$0")"
exec ./typecheck.sh App/AppModel.swift App/Navigation.swift Engine Brain Store Media UI/Theme Dev "$@"
