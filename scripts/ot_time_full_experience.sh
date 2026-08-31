#!/usr/bin/env bash
set -euo pipefail

: "${OIDC_TOKEN:?OIDC_TOKEN is required}"
: "${API_BASE:?API_BASE is required}"

REPOSITORY_REF="${REPOSITORY_REF:-github:Ryan9876/ot-time}"
COOKIE_JAR="${COOKIE_JAR:-/tmp/parallax-ot-time.cookies}"

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
    --output /tmp/parallax-ot-session.json \
    --write-out '%{http_code}' \
    --cookie-jar "${COOKIE_JAR}" \
    -H "Authorization: Bearer ${OIDC_TOKEN}" \
    -X POST "${API_BASE}/v1/session/qa-automation" || true)"
  if [ "${status}" = "200" ] && jq -e '.authenticated == true' /tmp/parallax-ot-session.json >/dev/null 2>&1; then
    authenticated=1
    break
  fi
  sleep 10
done
test "${authenticated}" = "1"
echo "QA phase: session established"

api "${API_BASE}/v1/projects" >/tmp/parallax-ot-projects.json
project_id="$(jq -r --arg repo "${REPOSITORY_REF}" '[.[] | select((.repository_ref // "" | ascii_downcase) == ($repo | ascii_downcase))][0].id // empty' /tmp/parallax-ot-projects.json)"
if [ -z "${project_id}" ]; then
  project_slug="qa-ot-time-${GITHUB_RUN_ID:-fixture}"
  jq -n \
    --arg name "QA OT Time Source-Only Acceptance" \
    --arg slug "${project_slug}" \
    --arg description "QA-only .NET source-only acceptance fixture; no source publication or application deployment." \
    --arg repository_ref "${REPOSITORY_REF}" \
    '{name:$name,slug:$slug,description:$description,repository_ref:$repository_ref,delivery_mode:"source-only"}' \
    >/tmp/parallax-ot-project-create.json
  api --data-binary @/tmp/parallax-ot-project-create.json \
    -X POST "${API_BASE}/v1/projects" >/tmp/parallax-ot-project.json
  project_id="$(jq -r '.id' /tmp/parallax-ot-project.json)"
else
  jq -n '{delivery_mode:"source-only"}' >/tmp/parallax-ot-delivery.json
  api --data-binary @/tmp/parallax-ot-delivery.json \
    -X PATCH "${API_BASE}/v1/projects/${project_id}/delivery" >/tmp/parallax-ot-project.json
fi
test -n "${project_id}"

jq -n --arg project_id "${project_id}" '{mode:"code",project_id:$project_id}' \
  >/tmp/parallax-ot-conversation-create.json
api --data-binary @/tmp/parallax-ot-conversation-create.json \
  -X POST "${API_BASE}/v1/conversations" >/tmp/parallax-ot-conversation.json
conversation_id="$(jq -r '.id' /tmp/parallax-ot-conversation.json)"

objective='This is an approved QA-only source-only production acceptance against Ryan9876/ot-time. Make one minimal, reversible, non-functional documentation addition named PARALLAX_QA.md. Do not change existing application behavior, delete or rename existing files, publish source, or deploy an application.'
jq -n --arg content "${objective}" '{role:"user",content:$content}' >/tmp/parallax-ot-message.json
api --data-binary @/tmp/parallax-ot-message.json \
  -X POST "${API_BASE}/v1/conversations/${conversation_id}/messages" >/tmp/parallax-ot-message-response.json

api -X POST "${API_BASE}/v1/conversations/${conversation_id}/work-specifications/draft" \
  >/tmp/parallax-ot-spec.json
work_specification_id="$(jq -r '.id' /tmp/parallax-ot-spec.json)"
test -n "${work_specification_id}"
api -X POST "${API_BASE}/v1/work-specifications/${work_specification_id}/approve" \
  >/tmp/parallax-ot-spec-approved.json
jq -e '.status == "APPROVED"' /tmp/parallax-ot-spec-approved.json >/dev/null

jq -n \
  --arg conversation_id "${conversation_id}" \
  --arg work_specification_id "${work_specification_id}" \
  '{conversation_id:$conversation_id,work_specification_id:$work_specification_id}' \
  >/tmp/parallax-ot-activate.json
api --data-binary @/tmp/parallax-ot-activate.json \
  -X POST "${API_BASE}/v1/engineering-runs/activate" >/tmp/parallax-ot-run-before.json
run_id="$(jq -r '.id' /tmp/parallax-ot-run-before.json)"
revision="$(jq -r '.revision' /tmp/parallax-ot-run-before.json)"
test "$(jq -r '.state' /tmp/parallax-ot-run-before.json)" = "PLAN"

operation_key="qa-ot-time-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
jq -n --arg operation_key "${operation_key}" --argjson expected_revision "${revision}" \
  '{operation_key:$operation_key,expected_revision:$expected_revision}' >/tmp/parallax-ot-autonomous.json
autonomous_status="$(curl --silent --show-error --max-time 900 \
  --output /tmp/parallax-ot-replay.json \
  --write-out '%{http_code}' \
  --cookie "${COOKIE_JAR}" \
  -H "X-Parallax-Session: 1" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/parallax-ot-autonomous.json \
  -X POST "${API_BASE}/v1/engineering-runs/${run_id}/autonomous")"
if [ "${autonomous_status}" != "200" ]; then
  jq -c '.' /tmp/parallax-ot-replay.json
  exit 1
fi

api "${API_BASE}/v1/engineering-runs/${run_id}" >/tmp/parallax-ot-run-after.json
state="$(jq -r '.state' /tmp/parallax-ot-run-after.json)"
failure="$(jq -r '.last_failure_code // ""' /tmp/parallax-ot-run-after.json)"
test "${state}" = "REVIEW"
test -z "${failure}"

api "${API_BASE}/v1/projects/${project_id}/engineering-runs/${run_id}/source-download" -o /tmp/parallax-ot-source.zip
python - <<'PY'
from pathlib import Path
from zipfile import ZipFile, is_zipfile

archive = Path('/tmp/parallax-ot-source.zip')
assert archive.is_file() and archive.stat().st_size > 0
assert is_zipfile(archive)
with ZipFile(archive) as zf:
    names = zf.namelist()
    assert 'PARALLAX_QA.md' in names
    assert all(not name.startswith('/') and '..' not in name.split('/') for name in names)
print(f'OT Time full experience accepted: entries={len(names)}, bytes={archive.stat().st_size}')
PY

echo "OT Time full-experience acceptance completed: project=${project_id}; run=${run_id}; state=${state}; source_publication=false; app_deployment=false"
