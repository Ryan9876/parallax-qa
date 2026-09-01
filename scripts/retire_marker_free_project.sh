#!/usr/bin/env bash
set -euo pipefail

: "${OIDC_TOKEN:?OIDC_TOKEN is required}"
: "${API_BASE:?API_BASE is required}"
: "${REPOSITORY_REF:?REPOSITORY_REF is required}"

COOKIE_JAR="${COOKIE_JAR:-/tmp/parallax-marker-free-retire.cookies}"

api() {
  curl --fail-with-body --silent --show-error \
    --cookie "${COOKIE_JAR}" \
    -H "X-Parallax-Session: 1" \
    -H "Content-Type: application/json" \
    "$@"
}

authenticated=0
for attempt in $(seq 1 36); do
  status="$(curl --silent --show-error \
    --output /tmp/parallax-marker-free-retire-session.json \
    --write-out '%{http_code}' \
    --cookie-jar "${COOKIE_JAR}" \
    -H "Authorization: Bearer ${OIDC_TOKEN}" \
    -X POST "${API_BASE}/v1/session/qa-automation" || true)"
  if [ "${status}" = "200" ] && jq -e '.authenticated == true' /tmp/parallax-marker-free-retire-session.json >/dev/null 2>&1; then
    authenticated=1
    break
  fi
  sleep 10
done
test "${authenticated}" = "1"

api "${API_BASE}/v1/projects" >/tmp/parallax-marker-free-retire-projects.json
mapfile -t project_ids < <(
  jq -r --arg repo "${REPOSITORY_REF}" \
    '.[] | select((.repository_ref // "" | ascii_downcase) == ($repo | ascii_downcase)) | .id' \
    /tmp/parallax-marker-free-retire-projects.json
)

for project_id in "${project_ids[@]:-}"; do
  [ -n "${project_id}" ] || continue

  api "${API_BASE}/v1/projects/${project_id}/agentic-observability?limit=25" \
    >/tmp/parallax-marker-free-retire-history.json

  while IFS=$'\t' read -r run_id run_state run_revision; do
    [ -n "${run_id}" ] || continue
    case "${run_state}" in
      COMPLETE|SPEC_AMENDMENT|CANCELLED) continue ;;
    esac

    jq -n \
      --arg operation_key "qa-retire-${run_id}-${run_revision}" \
      --argjson expected_revision "${run_revision}" \
      '{operation_key:$operation_key,expected_revision:$expected_revision}' \
      >/tmp/parallax-marker-free-retire-cancel.json

    status="$(curl --silent --show-error \
      --output /tmp/parallax-marker-free-retire-cancel-result.json \
      --write-out '%{http_code}' \
      --cookie "${COOKIE_JAR}" \
      -H "X-Parallax-Session: 1" \
      -H "Content-Type: application/json" \
      --data-binary @/tmp/parallax-marker-free-retire-cancel.json \
      -X POST "${API_BASE}/v1/engineering-runs/${run_id}/cancel" || true)"
    test "${status}" = "200"
    jq -e '.run.state == "CANCELLED"' /tmp/parallax-marker-free-retire-cancel-result.json >/dev/null
    echo "QA phase: cancelled prior fixture run ${run_id}"
  done < <(
    jq -r '.runs[]? | [.run_id,.run_state,(.run_revision|tostring)] | @tsv' \
      /tmp/parallax-marker-free-retire-history.json
  )

  status="$(curl --silent --show-error \
    --output /tmp/parallax-marker-free-retire-delete.json \
    --write-out '%{http_code}' \
    --cookie "${COOKIE_JAR}" \
    -H "X-Parallax-Session: 1" \
    -X DELETE "${API_BASE}/v1/projects/${project_id}" || true)"
  test "${status}" = "204"
  echo "QA phase: retired prior marker-free Project ${project_id}"
done
