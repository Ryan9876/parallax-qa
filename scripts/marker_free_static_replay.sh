#!/usr/bin/env bash
set -euo pipefail

: "${OIDC_TOKEN:?OIDC_TOKEN is required}"
: "${API_BASE:?API_BASE is required}"
: "${REPOSITORY_REF:?REPOSITORY_REF is required}"

COOKIE_JAR="${COOKIE_JAR:-/tmp/parallax-marker-free.cookies}"
MAX_AUTONOMY_REQUESTS=8
AUTONOMY_REQUEST_TIMEOUT_SECONDS=300

api() {
  curl --fail-with-body --silent --show-error \
    --cookie "${COOKIE_JAR}" \
    -H "X-Parallax-Session: 1" \
    -H "Content-Type: application/json" \
    "$@"
}

# AC-12 requires an equivalent marker-free greenfield run. Refuse to reuse a
# repository that already has source so the trusted QA path cannot silently
# degrade into an established-source replay.
repo_url="https://github.com/${REPOSITORY_REF#github:}.git"
refs="$(git ls-remote "${repo_url}")"
if [ -n "${refs}" ]; then
  echo "Marker-free QA target is not empty: ${REPOSITORY_REF}" >&2
  exit 1
fi
echo "QA phase: empty marker-free repository verified (${REPOSITORY_REF})"

authenticated=0
for attempt in $(seq 1 36); do
  status="$(curl --silent --show-error \
    --output /tmp/parallax-marker-free-session.json \
    --write-out '%{http_code}' \
    --cookie-jar "${COOKIE_JAR}" \
    -H "Authorization: Bearer ${OIDC_TOKEN}" \
    -X POST "${API_BASE}/v1/session/qa-automation" || true)"
  if [ "${status}" = "200" ] && jq -e '.authenticated == true' /tmp/parallax-marker-free-session.json >/dev/null 2>&1; then
    authenticated=1
    break
  fi
  sleep 10
done
test "${authenticated}" = "1"
echo "QA phase: trusted production session established"

# This repository is dedicated to disposable QA. Remove an older QA-owned
# Project bound to the exact fixture repository so each replay starts with no
# accepted Project source lineage. This is ordinary owner-scoped product
# deletion, not a database or authorization bypass.
api "${API_BASE}/v1/projects" >/tmp/parallax-marker-free-projects.json
mapfile -t old_projects < <(jq -r --arg repo "${REPOSITORY_REF}" '.[] | select((.repository_ref // "" | ascii_downcase) == ($repo | ascii_downcase)) | .id' /tmp/parallax-marker-free-projects.json)
for old_project_id in "${old_projects[@]:-}"; do
  [ -n "${old_project_id}" ] || continue
  status="$(curl --silent --show-error \
    --output /tmp/parallax-marker-free-delete.json \
    --write-out '%{http_code}' \
    --cookie "${COOKIE_JAR}" \
    -H "X-Parallax-Session: 1" \
    -X DELETE "${API_BASE}/v1/projects/${old_project_id}" || true)"
  test "${status}" = "204"
  echo "QA phase: retired prior QA Project ${old_project_id}"
done

project_slug="qa-marker-free-${GITHUB_RUN_ID:-fixture}-${GITHUB_RUN_ATTEMPT:-1}"
jq -n \
  --arg name "QA Marker-Free Static" \
  --arg slug "${project_slug}" \
  --arg description "QA-only marker-free source-only P2-V0.23.32 acceptance fixture; no source publication or application deployment." \
  --arg repository_ref "${REPOSITORY_REF}" \
  '{name:$name,slug:$slug,description:$description,repository_ref:$repository_ref,delivery_mode:"source-only"}' \
  >/tmp/parallax-marker-free-project-create.json
api --data-binary @/tmp/parallax-marker-free-project-create.json \
  -X POST "${API_BASE}/v1/projects" >/tmp/parallax-marker-free-project.json
project_id="$(jq -r '.id' /tmp/parallax-marker-free-project.json)"
test -n "${project_id}"
echo "QA phase: fresh Project created (${project_id})"

jq -n --arg project_id "${project_id}" '{mode:"code",project_id:$project_id}' \
  >/tmp/parallax-marker-free-conversation-create.json
api --data-binary @/tmp/parallax-marker-free-conversation-create.json \
  -X POST "${API_BASE}/v1/conversations" >/tmp/parallax-marker-free-conversation.json
conversation_id="$(jq -r '.id' /tmp/parallax-marker-free-conversation.json)"

objective='This is an approved QA-only source-only marker-free greenfield acceptance test. Create a self-contained static web application that works offline with a root index.html, local styles.css, and local app.js. The page must visibly show the heading "Parallax QA Static", a count that starts at 0, and a button that increments the count. It must also display a local image from assets/qa-mark.svg and a local favicon from assets/favicon.svg. Keep all HTML, CSS, JavaScript, and image assets local. Do not use frameworks, package managers, bundlers, repository scripts, external network resources, source publication, or application deployment. The complete source should be suitable for the protected static-web BUILD, TEST, and VERIFY contract.'
jq -n --arg content "${objective}" '{role:"user",content:$content}' >/tmp/parallax-marker-free-message.json
api --data-binary @/tmp/parallax-marker-free-message.json \
  -X POST "${API_BASE}/v1/conversations/${conversation_id}/messages" >/tmp/parallax-marker-free-message-response.json

api -X POST "${API_BASE}/v1/conversations/${conversation_id}/work-specifications/draft" \
  >/tmp/parallax-marker-free-spec.json
work_specification_id="$(jq -r '.id' /tmp/parallax-marker-free-spec.json)"
test -n "${work_specification_id}"
api -X POST "${API_BASE}/v1/work-specifications/${work_specification_id}/approve" \
  >/tmp/parallax-marker-free-spec-approved.json
jq -e '.status == "APPROVED"' /tmp/parallax-marker-free-spec-approved.json >/dev/null

jq -n \
  --arg conversation_id "${conversation_id}" \
  --arg work_specification_id "${work_specification_id}" \
  '{conversation_id:$conversation_id,work_specification_id:$work_specification_id}' \
  >/tmp/parallax-marker-free-activate.json
api --data-binary @/tmp/parallax-marker-free-activate.json \
  -X POST "${API_BASE}/v1/engineering-runs/activate" >/tmp/parallax-marker-free-run.json
run_id="$(jq -r '.id' /tmp/parallax-marker-free-run.json)"
revision="$(jq -r '.revision' /tmp/parallax-marker-free-run.json)"
state="$(jq -r '.state' /tmp/parallax-marker-free-run.json)"
test "${state}" = "PLAN"
echo "QA Engineering Run: ${run_id}"

completed_requests=0
for request_index in $(seq 1 "${MAX_AUTONOMY_REQUESTS}"); do
  operation_key="p2332-marker-free-${run_id}-${revision}"
  jq -n --arg operation_key "${operation_key}" --argjson expected_revision "${revision}" \
    '{operation_key:$operation_key,expected_revision:$expected_revision}' >/tmp/parallax-marker-free-autonomous.json

  autonomous_status="$(curl --silent --show-error --max-time "${AUTONOMY_REQUEST_TIMEOUT_SECONDS}" \
    --output /tmp/parallax-marker-free-result.json \
    --write-out '%{http_code}' \
    --cookie "${COOKIE_JAR}" \
    -H "X-Parallax-Session: 1" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/parallax-marker-free-autonomous.json \
    -X POST "${API_BASE}/v1/engineering-runs/${run_id}/autonomous" || true)"

  if [ "${autonomous_status}" != "200" ]; then
    echo "QA autonomy HTTP failure: request=${request_index}; status=${autonomous_status}"
    cat /tmp/parallax-marker-free-result.json || true
    break
  fi

  completed_requests="${request_index}"
  state="$(jq -r '.run.state' /tmp/parallax-marker-free-result.json)"
  revision="$(jq -r '.run.revision' /tmp/parallax-marker-free-result.json)"
  failure="$(jq -r '.run.last_failure_code // ""' /tmp/parallax-marker-free-result.json)"
  stop_reason="$(jq -r '.stop_reason // ""' /tmp/parallax-marker-free-result.json)"
  echo "QA autonomy request ${request_index}: state=${state}; revision=${revision}; stop_reason=${stop_reason}; failure=${failure:-none}"

  if [ "${state}" = "REVIEW" ] || [ "${state}" = "FAILED" ]; then
    break
  fi
  case "${state}" in
    PLAN|IMPLEMENT|BUILD|TEST|VERIFY) ;;
    *) echo "Unexpected autonomous continuation state: ${state}" >&2; exit 1 ;;
  esac
done

api "${API_BASE}/v1/engineering-runs/${run_id}" >/tmp/parallax-marker-free-run-final.json
curl --fail-with-body --silent --show-error \
  --cookie "${COOKIE_JAR}" \
  -H "X-Parallax-Session: 1" \
  "${API_BASE}/v1/engineering-runs/${run_id}/events" >/tmp/parallax-marker-free-events.json

state="$(jq -r '.state' /tmp/parallax-marker-free-run-final.json)"
failure="$(jq -r '.last_failure_code // ""' /tmp/parallax-marker-free-run-final.json)"
echo "QA final: project=${project_id}; conversation=${conversation_id}; spec=${work_specification_id}; run=${run_id}; requests=${completed_requests}; state=${state}; failure=${failure:-none}"
echo 'QA IMPLEMENT attempts:'
jq -c '.attempts[]? | select(.stage == "IMPLEMENT")' /tmp/parallax-marker-free-run-final.json || true
echo 'QA durable events:'
jq -c '.' /tmp/parallax-marker-free-events.json || true

if [ "${state}" = "REVIEW" ]; then
  test -z "${failure}"
  api "${API_BASE}/v1/projects/${project_id}/engineering-runs/${run_id}/source-download" -o /tmp/parallax-marker-free-source.zip
  python - <<'PY'
from zipfile import ZipFile, is_zipfile
p = '/tmp/parallax-marker-free-source.zip'
assert is_zipfile(p)
with ZipFile(p) as zf:
    names = set(zf.namelist())
    assert 'index.html' in names
    assert 'styles.css' in names
    assert 'app.js' in names
print('QA marker-free source accepted through REVIEW')
PY
  exit 0
fi

# FAILED is useful bounded evidence for diagnosis; preserve logs/artifacts but
# fail the trusted replay so it cannot be mistaken for acceptance.
exit 1
