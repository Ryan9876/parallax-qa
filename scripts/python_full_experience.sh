#!/usr/bin/env bash
set -euo pipefail

: "${OIDC_TOKEN:?OIDC_TOKEN is required}"
: "${API_BASE:?API_BASE is required}"

REPOSITORY_REF="${REPOSITORY_REF:-github:Ryan9876/Movies}"
COOKIE_JAR="${COOKIE_JAR:-/tmp/parallax-python-full-experience.cookies}"

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
    --output /tmp/parallax-python-session.json \
    --write-out '%{http_code}' \
    --cookie-jar "${COOKIE_JAR}" \
    -H "Authorization: Bearer ${OIDC_TOKEN}" \
    -X POST "${API_BASE}/v1/session/qa-automation" || true)"
  if [ "${status}" = "200" ] && jq -e '.authenticated == true' /tmp/parallax-python-session.json >/dev/null 2>&1; then
    authenticated=1
    break
  fi
  sleep 10
done
test "${authenticated}" = "1"
echo "QA phase: session established"

api "${API_BASE}/v1/projects" >/tmp/parallax-python-projects.json
project_id="$(jq -r --arg repo "${REPOSITORY_REF}" '[.[] | select((.repository_ref // "" | ascii_downcase) == ($repo | ascii_downcase))][0].id // empty' /tmp/parallax-python-projects.json)"
if [ -z "${project_id}" ]; then
  project_slug="qa-python-full-experience-${GITHUB_RUN_ID:-fixture}"
  jq -n \
    --arg name "QA Python Full Experience" \
    --arg slug "${project_slug}" \
    --arg description "QA-only source-only acceptance fixture; no source publication or application deployment." \
    --arg repository_ref "${REPOSITORY_REF}" \
    '{name:$name,slug:$slug,description:$description,repository_ref:$repository_ref,delivery_mode:"source-only"}' \
    >/tmp/parallax-python-project-create.json
  api --data-binary @/tmp/parallax-python-project-create.json \
    -X POST "${API_BASE}/v1/projects" >/tmp/parallax-python-project.json
  project_id="$(jq -r '.id' /tmp/parallax-python-project.json)"
else
  jq -n '{delivery_mode:"source-only"}' >/tmp/parallax-python-delivery.json
  api --data-binary @/tmp/parallax-python-delivery.json \
    -X PATCH "${API_BASE}/v1/projects/${project_id}/delivery" >/tmp/parallax-python-project.json
fi
test -n "${project_id}"

jq -n --arg project_id "${project_id}" '{mode:"code",project_id:$project_id}' \
  >/tmp/parallax-python-conversation-create.json
api --data-binary @/tmp/parallax-python-conversation-create.json \
  -X POST "${API_BASE}/v1/conversations" >/tmp/parallax-python-conversation.json
conversation_id="$(jq -r '.id' /tmp/parallax-python-conversation.json)"

objective='This is an approved QA-only source-only end-to-end test. Make one minimal, reversible, non-functional documentation addition named PARALLAX_QA_PYTHON.md that states it is a disposable full-experience acceptance fixture. Do not modify application behavior, delete or rename files, publish source, or deploy an application.'
jq -n --arg content "${objective}" '{role:"user",content:$content}' >/tmp/parallax-python-message.json
api --data-binary @/tmp/parallax-python-message.json \
  -X POST "${API_BASE}/v1/conversations/${conversation_id}/messages" >/tmp/parallax-python-message-response.json

api -X POST "${API_BASE}/v1/conversations/${conversation_id}/work-specifications/draft" \
  >/tmp/parallax-python-spec.json
work_specification_id="$(jq -r '.id' /tmp/parallax-python-spec.json)"
test -n "${work_specification_id}"
api -X POST "${API_BASE}/v1/work-specifications/${work_specification_id}/approve" \
  >/tmp/parallax-python-spec-approved.json
jq -e '.status == "APPROVED"' /tmp/parallax-python-spec-approved.json >/dev/null

jq -n \
  --arg conversation_id "${conversation_id}" \
  --arg work_specification_id "${work_specification_id}" \
  '{conversation_id:$conversation_id,work_specification_id:$work_specification_id}' \
  >/tmp/parallax-python-activate.json
api --data-binary @/tmp/parallax-python-activate.json \
  -X POST "${API_BASE}/v1/engineering-runs/activate" >/tmp/parallax-python-run-before.json
run_id="$(jq -r '.id' /tmp/parallax-python-run-before.json)"
revision="$(jq -r '.revision' /tmp/parallax-python-run-before.json)"
test "$(jq -r '.state' /tmp/parallax-python-run-before.json)" = "PLAN"

operation_key="qa-python-full-experience-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
jq -n --arg operation_key "${operation_key}" --argjson expected_revision "${revision}" \
  '{operation_key:$operation_key,expected_revision:$expected_revision}' >/tmp/parallax-python-autonomous.json
autonomous_status="$(curl --silent --show-error --max-time 900 \
  --output /tmp/parallax-python-replay.json \
  --write-out '%{http_code}' \
  --cookie "${COOKIE_JAR}" \
  -H "X-Parallax-Session: 1" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/parallax-python-autonomous.json \
  -X POST "${API_BASE}/v1/engineering-runs/${run_id}/autonomous")"
if [ "${autonomous_status}" != "200" ]; then
  jq -c '.' /tmp/parallax-python-replay.json
  exit 1
fi

api "${API_BASE}/v1/engineering-runs/${run_id}" >/tmp/parallax-python-run-after.json
state="$(jq -r '.state' /tmp/parallax-python-run-after.json)"
failure="$(jq -r '.last_failure_code // ""' /tmp/parallax-python-run-after.json)"
test "${state}" = "REVIEW"
test -z "${failure}"

api "${API_BASE}/v1/projects/${project_id}/engineering-runs/${run_id}/source-download" -o /tmp/parallax-python-source.zip
python - <<'PY'
from pathlib import Path
from zipfile import ZipFile, is_zipfile

archive = Path('/tmp/parallax-python-source.zip')
assert archive.is_file() and archive.stat().st_size > 0
assert is_zipfile(archive)
with ZipFile(archive) as zf:
    names = zf.namelist()
    assert 'PARALLAX_QA_PYTHON.md' in names
    assert all(not name.startswith('/') and '..' not in name.split('/') for name in names)
print(f'Python full experience accepted: entries={len(names)}, bytes={archive.stat().st_size}')
PY

echo "Python full-experience acceptance completed: project=${project_id}; run=${run_id}; state=${state}; source_publication=false; app_deployment=false"
