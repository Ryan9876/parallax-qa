#!/usr/bin/env bash
set -euo pipefail

api_base="${API_BASE:-https://parallax-api-tan.vercel.app}"
run_id="${RUN_ID:-a64d56b7-ad42-42ad-9562-891783363f4a}"
qa_cookie_jar="${cookie_jar:-${PARALLAX_QA_COOKIE_JAR:-}}"

if [[ -z "${qa_cookie_jar}" || ! -f "${qa_cookie_jar}" ]]; then
  echo "P2-V0.23.47 acceptance requires an already-authenticated Parallax QA session cookie jar." >&2
  exit 64
fi

auth_curl=(--fail-with-body --silent --show-error --cookie "${qa_cookie_jar}" -H "X-Parallax-Session: 1")

canonical_hash() {
  jq -cS . "$1" | sha256sum | awk '{print $1}'
}

echo "P2-V0.23.47 behavioral verification plan acceptance: starting"

curl "${auth_curl[@]}" "${api_base}/v1/engineering-runs/${run_id}" > /tmp/p02347-run-before.json
spec_id="$(jq -r '.work_specification_id' /tmp/p02347-run-before.json)"
conversation_id="$(jq -r '.conversation_id' /tmp/p02347-run-before.json)"

test -n "${spec_id}" && test "${spec_id}" != "null"
test -n "${conversation_id}" && test "${conversation_id}" != "null"

jq -e '.state == "REVIEW" and .revision == 12 and .last_failure_code == null' /tmp/p02347-run-before.json >/dev/null
run_before_hash="$(canonical_hash /tmp/p02347-run-before.json)"

curl "${auth_curl[@]}" "${api_base}/v1/conversations/${conversation_id}/work-specifications/approved" > /tmp/p02347-spec-before.json
jq -e --arg spec "${spec_id}" '.id == $spec and .status == "APPROVED" and .revision == 1' /tmp/p02347-spec-before.json >/dev/null
spec_before_hash="$(canonical_hash /tmp/p02347-spec-before.json)"

curl "${auth_curl[@]}" "${api_base}/v1/engineering-runs/${run_id}/events?after_sequence=0&limit=100" > /tmp/p02347-events-before.json
events_before_hash="$(canonical_hash /tmp/p02347-events-before.json)"

curl "${auth_curl[@]}" "${api_base}/v1/work-specifications/${spec_id}/behavioral-verification-plan" > /tmp/p02347-plan-before.json
prior_revision="$(jq -r 'if . == null then 0 else .revision end' /tmp/p02347-plan-before.json)"

draft_status="$(curl --max-time 240 --silent --show-error --output /tmp/p02347-plan-draft.json --write-out '%{http_code}' --cookie "${qa_cookie_jar}" -H "X-Parallax-Session: 1" -X POST "${api_base}/v1/work-specifications/${spec_id}/behavioral-verification-plan/draft")"
echo "Behavioral plan draft status=${draft_status}"
test "${draft_status}" = "200"

jq -e --arg spec "${spec_id}" '.work_specification_id == $spec and .work_specification_revision == 1 and .status == "DRAFT"' /tmp/p02347-plan-draft.json >/dev/null
draft_revision="$(jq -r '.revision' /tmp/p02347-plan-draft.json)"
test "${draft_revision}" -gt "${prior_revision}"

spec_count="$(jq '.acceptance_criteria | length' /tmp/p02347-spec-before.json)"
plan_count="$(jq '.criteria | length' /tmp/p02347-plan-draft.json)"
test "${spec_count}" -gt 0
test "${plan_count}" -eq "${spec_count}"

for i in $(seq 0 $((spec_count - 1))); do
  expected_id="$(printf 'AC-%02d' $((i + 1)))"
  jq -e --argjson i "${i}" --arg expected_id "${expected_id}" --slurpfile spec /tmp/p02347-spec-before.json '
    .criteria[$i].acceptance_id == $expected_id
    and .criteria[$i].acceptance_text == $spec[0].acceptance_criteria[$i]
  ' /tmp/p02347-plan-draft.json >/dev/null
done

jq -e '
  all(.criteria[];
    if .mode == "HUMAN_ONLY" then
      .workflow == null
    elif .mode == "BROWSER" then
      (.workflow | type) == "object"
    else
      false
    end
  )
' /tmp/p02347-plan-draft.json >/dev/null

computed_digest="$(jq -cS '{schema_version: 1, criteria: .criteria}' /tmp/p02347-plan-draft.json | sha256sum | awk '{print $1}')"
persisted_digest="$(jq -r '.plan_digest' /tmp/p02347-plan-draft.json)"
test "${computed_digest}" = "${persisted_digest}"

plan_id="$(jq -r '.id' /tmp/p02347-plan-draft.json)"
curl "${auth_curl[@]}" "${api_base}/v1/work-specifications/${spec_id}/behavioral-verification-plan" > /tmp/p02347-plan-read.json
jq -e --arg id "${plan_id}" --arg digest "${persisted_digest}" '.id == $id and .status == "DRAFT" and .plan_digest == $digest' /tmp/p02347-plan-read.json >/dev/null

approve_status="$(curl --silent --show-error --output /tmp/p02347-plan-approved.json --write-out '%{http_code}' --cookie "${qa_cookie_jar}" -H "X-Parallax-Session: 1" -X POST "${api_base}/v1/behavioral-verification-plans/${plan_id}/approve")"
echo "Behavioral plan approval status=${approve_status}"
test "${approve_status}" = "200"
jq -e --arg id "${plan_id}" --arg digest "${persisted_digest}" '.id == $id and .status == "APPROVED" and .plan_digest == $digest and .approved_at != null' /tmp/p02347-plan-approved.json >/dev/null
approved_hash="$(canonical_hash /tmp/p02347-plan-approved.json)"

replay_status="$(curl --silent --show-error --output /tmp/p02347-plan-approved-replay.json --write-out '%{http_code}' --cookie "${qa_cookie_jar}" -H "X-Parallax-Session: 1" -X POST "${api_base}/v1/behavioral-verification-plans/${plan_id}/approve")"
echo "Behavioral plan replay approval status=${replay_status}"
test "${replay_status}" = "200"
test "$(canonical_hash /tmp/p02347-plan-approved-replay.json)" = "${approved_hash}"

curl "${auth_curl[@]}" "${api_base}/v1/work-specifications/${spec_id}/behavioral-verification-plan" > /tmp/p02347-plan-after.json
jq -e --arg id "${plan_id}" --arg digest "${persisted_digest}" '.id == $id and .status == "APPROVED" and .plan_digest == $digest' /tmp/p02347-plan-after.json >/dev/null

curl "${auth_curl[@]}" "${api_base}/v1/conversations/${conversation_id}/work-specifications/approved" > /tmp/p02347-spec-after.json
curl "${auth_curl[@]}" "${api_base}/v1/engineering-runs/${run_id}" > /tmp/p02347-run-after.json
curl "${auth_curl[@]}" "${api_base}/v1/engineering-runs/${run_id}/events?after_sequence=0&limit=100" > /tmp/p02347-events-after.json

test "$(canonical_hash /tmp/p02347-spec-after.json)" = "${spec_before_hash}"
test "$(canonical_hash /tmp/p02347-run-after.json)" = "${run_before_hash}"
test "$(canonical_hash /tmp/p02347-events-after.json)" = "${events_before_hash}"

echo "P2-V0.23.47 production behavioral verification plan acceptance: PASS"
echo "work_specification_id=${spec_id}"
echo "work_specification_revision=1"
echo "work_specification_hash=${spec_before_hash}"
echo "engineering_run_id=${run_id}"
echo "engineering_run_revision=12"
echo "engineering_run_hash=${run_before_hash}"
echo "engineering_run_events_hash=${events_before_hash}"
echo "plan_id=${plan_id}"
echo "plan_revision=${draft_revision}"
echo "plan_digest=${persisted_digest}"
echo "acceptance_count=${spec_count}"
echo "approval_replay_hash=${approved_hash}"

# This file is intended to be sourced immediately after the trusted QA session
# is established. Exiting here prevents the older historical replay assertions
# later in that workflow step from running against the now-revision-12 W9-S1 run.
exit 0
