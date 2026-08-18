#!/usr/bin/env bash
# Quick smoke test for a deployed Tamaso instance.
# Usage: ./smoke-test.sh <app_host>
# Example: ./smoke-test.sh 35.200.182.98.sslip.io
set -euo pipefail

HOST="${1:?Usage: smoke-test.sh <app_host>}"
PASS=0
FAIL=0

check() {
  local name="$1"
  local result="$2"
  printf "%-35s" "${name}..."
  if [[ "$result" == "PASS" ]]; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL ($result)"
    ((FAIL++))
  fi
}

echo "Smoke testing: https://${HOST}"
echo "==========================================="

# Backend health
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "https://${HOST}/api/backend/health/" 2>/dev/null || echo "000")
[[ "$STATUS" == "200" ]] && check "Backend health" "PASS" || check "Backend health" "$STATUS"

# Frontend loads
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "https://${HOST}/" 2>/dev/null || echo "000")
[[ "$STATUS" == "200" ]] && check "Frontend loads" "PASS" || check "Frontend loads" "$STATUS"

# Admin panel
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "https://${HOST}/admin/login/" 2>/dev/null || echo "000")
[[ "$STATUS" == "200" ]] && check "Admin panel" "PASS" || check "Admin panel" "$STATUS"

# TLS certificate
TLS=$(curl -vI "https://${HOST}/" 2>&1 | grep -c "SSL certificate verify ok" || echo "0")
[[ "$TLS" -ge 1 ]] && check "TLS certificate" "PASS" || check "TLS certificate" "invalid"

# HTTP to HTTPS redirect
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "http://${HOST}/" 2>/dev/null || echo "000")
[[ "$STATUS" == "301" || "$STATUS" == "308" ]] && check "HTTP → HTTPS redirect" "PASS" || check "HTTP → HTTPS redirect" "$STATUS"

# Static files
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "https://${HOST}/static/admin/css/base.css" 2>/dev/null || echo "000")
[[ "$STATUS" == "200" ]] && check "Static files served" "PASS" || check "Static files served" "$STATUS"

echo "==========================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
