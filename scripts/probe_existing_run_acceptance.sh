#!/usr/bin/env bash
set -euo pipefail

: "${OIDC_TOKEN:?OIDC_TOKEN is required}"
: "${API_BASE:?API_BASE is required}"

RUN_ID="${RUN_ID:-3a1ba66a-5649-42b6-81ee-91684fe06bbc}"
COOKIE_JAR="${COOKIE_JAR:-/tmp/parallax-existing-run-probe.cookies}"
MAX_AUTONOMY_REQUESTS=8
AUTONOMY_REQUEST_TIMEOUT_SECONDS=300

session_status="$(curl --silent --show-error \
  --output /tmp/parallax-existing-session.json \
  --write-out '%{http_code}' \
  --cookie-jar "${COOKIE_JAR}" \
  -H "Authorization: Bearer ${OIDC_TOKEN}" \
  -X POST "${API_BASE}/v1/session/qa-automation" || true)"
test "${session_status}" = "200"
jq -e '.authenticated == true' /tmp/parallax-existing-session.json >/dev/null

auth_header=(-H "X-Parallax-Session: 1" -H "Content-Type: application/json" --cookie "${COOKIE_JAR}")
read_status="$(curl --silent --show-error \
  --output /tmp/parallax-existing-run.json \
  --write-out '%{http_code}' \
  "${auth_header[@]}" \
  "${API_BASE}/v1/engineering-runs/${RUN_ID}" || true)"

if [ "${read_status}" != "200" ]; then
  echo "QA existing-run probe: inaccessible under ordinary QA principal; status=${read_status}; run=${RUN_ID}"
  cat /tmp/parallax-existing-run.json || true
  exit 0
fi

state="$(jq -r '.state' /tmp/parallax-existing-run.json)"
revision="$(jq -r '.revision' /tmp/parallax-existing-run.json)"
failure="$(jq -r '.last_failure_code // ""' /tmp/parallax-existing-run.json)"
echo "QA existing-run probe: accessible; run=${RUN_ID}; state=${state}; revision=${revision}; failure=${failure:-none}"

if [ "${state}" = "FAILED" ] || [ "${state}" = "PAUSED" ]; then
  jq -n \
    --arg operation_key "qa-existing-resume-${RUN_ID}-${revision}" \
    --argjson expected_revision "${revision}" \
    '{operation_key:$operation_key,expected_revision:$expected_revision}' \
    >/tmp/parallax-existing-operation.json
  resume_status="$(curl --silent --show-error --max-time 120 \
    --output /tmp/parallax-existing-resume.json \
    --write-out '%{http_code}' \
    "${auth_header[@]}" \
    --data-binary @/tmp/parallax-existing-operation.json \
    -X POST "${API_BASE}/v1/engineering-runs/${RUN_ID}/resume" || true)"
  echo "QA existing-run resume: status=${resume_status}"
  cat /tmp/parallax-existing-resume.json || true
  if [ "${resume_status}" != "200" ]; then
    exit 1
  fi
  state="$(jq -r '.run.state' /tmp/parallax-existing-resume.json)"
  revision="$(jq -r '.run.revision' /tmp/parallax-existing-resume.json)"
fi

for request_index in $(seq 1 "${MAX_AUTONOMY_REQUESTS}"); do
  case "${state}" in
    REVIEW|FAILED|COMPLETE|SPEC_AMENDMENT|CANCELLED) break ;;
    PLAN|IMPLEMENT|BUILD|TEST|VERIFY) ;;
    *) echo "QA existing-run probe: unexpected state=${state}"; break ;;
  esac

  jq -n \
    --arg operation_key "qa-existing-autonomous-${RUN_ID}-${revision}" \
    --argjson expected_revision "${revision}" \
    '{operation_key:$operation_key,expected_revision:$expected_revision}' \
    >/tmp/parallax-existing-operation.json

  autonomous_status="$(curl --silent --show-error --max-time "${AUTONOMY_REQUEST_TIMEOUT_SECONDS}" \
    --output /tmp/parallax-existing-autonomous.json \
    --write-out '%{http_code}' \
    "${auth_header[@]}" \
    --data-binary @/tmp/parallax-existing-operation.json \
    -X POST "${API_BASE}/v1/engineering-runs/${RUN_ID}/autonomous" || true)"
  echo "QA existing-run autonomous ${request_index}: status=${autonomous_status}"
  cat /tmp/parallax-existing-autonomous.json || true
  if [ "${autonomous_status}" != "200" ]; then
    break
  fi
  state="$(jq -r '.run.state' /tmp/parallax-existing-autonomous.json)"
  revision="$(jq -r '.run.revision' /tmp/parallax-existing-autonomous.json)"
  failure="$(jq -r '.run.last_failure_code // ""' /tmp/parallax-existing-autonomous.json)"
done

curl --silent --show-error \
  --output /tmp/parallax-existing-final.json \
  "${auth_header[@]}" \
  "${API_BASE}/v1/engineering-runs/${RUN_ID}" || true
curl --silent --show-error \
  --output /tmp/parallax-existing-events.json \
  "${auth_header[@]}" \
  "${API_BASE}/v1/engineering-runs/${RUN_ID}/events" || true

echo 'QA existing-run final:'
cat /tmp/parallax-existing-final.json || true
echo
echo 'QA existing-run events:'
cat /tmp/parallax-existing-events.json || true

echo
if jq -e '.state == "REVIEW" and (.last_failure_code == null)' /tmp/parallax-existing-final.json >/dev/null 2>&1; then
  echo "QA existing-run acceptance reached REVIEW"
  exit 0
fi

# A later bounded blocker may still satisfy the governed acceptance condition,
# but the harness deliberately returns failure so release closure requires human
# inspection of the durable bounded evidence rather than treating any failure as success.
exit 1
