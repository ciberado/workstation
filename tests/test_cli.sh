#!/bin/bash

# Offline regression tests for launch and centralized file-management behavior.
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH_SCRIPT="${TEST_ROOT}/src/launch.sh"
MANAGE_SCRIPT="${TEST_ROOT}/src/manage-files.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_contains() {
    local actual="$1"
    local expected="$2"
    [[ "${actual}" == *"${expected}"* ]] || fail "expected: ${expected}"
}

bash -n "${TEST_ROOT}/src/launch.sh" "${TEST_ROOT}/src/destroy.sh" \
    "${TEST_ROOT}/src/userdata.sh" "${MANAGE_SCRIPT}"

help_output=$("${LAUNCH_SCRIPT}" --help)
assert_contains "${help_output}" "--workstation-name <name>"
assert_contains "${help_output}" "--seats <number>"
assert_contains "${help_output}" "--region <region>"

dry_output=$("${LAUNCH_SCRIPT}" --workstation-name test-seats --size small \
    --region eu-west-1 --seats 3 --dry)
assert_contains "${dry_output}" "Instance type: t3.small"
assert_contains "${dry_output}" "AWS Region: eu-west-1"
assert_contains "${dry_output}" "Seats: 3 (login required)"
assert_contains "${dry_output}" "no Termfleet or AWS requests were made"

no_seat_output=$("${LAUNCH_SCRIPT}" --workstation-name test-autologin --dry)
assert_contains "${no_seat_output}" "Seats: disabled (automatic ubuntu login)"

for size_mapping in small:t3.small medium:t3.medium large:t3.large xlarge:t3.xlarge; do
    size_name="${size_mapping%%:*}"
    instance_type="${size_mapping##*:}"
    size_output=$("${LAUNCH_SCRIPT}" --workstation-name "test-${size_name}" --size "${size_name}" --dry)
    assert_contains "${size_output}" "Instance type: ${instance_type}"
done

precedence_output=$(WORKSTATION_NAME=environment-name INSTANCE_SIZE=large AWS_DEFAULT_REGION=eu-west-1 \
    "${LAUNCH_SCRIPT}" --workstation-name cli-name --size small --region us-east-1 --dry)
assert_contains "${precedence_output}" "Workstation name: cli-name"
assert_contains "${precedence_output}" "Instance type: t3.small"
assert_contains "${precedence_output}" "AWS Region: us-east-1"

if "${LAUNCH_SCRIPT}" --workstation-name invalid_name --seats 1 --dry >/dev/null 2>&1; then
    fail "invalid workstation name was accepted"
fi

if "${LAUNCH_SCRIPT}" --workstation-name test-seats --seats 0 --dry >/dev/null 2>&1; then
    fail "zero seats was accepted"
fi

ssh() {
    printf 'SEAT_COUNT=3\n'
}
export -f ssh

manage_output=$("${MANAGE_SCRIPT}" push --host test.example.com --source "${TEST_ROOT}/README.md" \
    --path .aws --transport ssh --region eu-west-1 --dry-run)
assert_contains "${manage_output}" "/home/student1/.aws"
assert_contains "${manage_output}" "/home/student3/.aws"
assert_contains "${manage_output}" "Using direct SSH for test.example.com"

manage_help=$("${MANAGE_SCRIPT}" --help)
assert_contains "${manage_help}" "--transport <mode>"
assert_contains "${manage_help}" "--region <region>"

ssh() {
    if [[ "$*" == *"ProxyCommand=aws ssm start-session"* ]]; then
        printf 'SEAT_COUNT=2\n'
    else
        return 1
    fi
}

aws() {
    printf 'i-0123456789abcdef0\n'
}

session-manager-plugin() {
    :
}
export -f ssh aws session-manager-plugin

ssm_output=$("${MANAGE_SCRIPT}" push --host 192.0.2.10 --seats 2 --source "${TEST_ROOT}/README.md" \
    --path lab-01 --transport auto --dry-run)
assert_contains "${ssm_output}" "falling back to Session Manager"
assert_contains "${ssm_output}" "Using Session Manager for 192.0.2.10 (i-0123456789abcdef0)"

if "${MANAGE_SCRIPT}" remove --host test.example.com --seats 2 --path lab-01 >/dev/null 2>&1; then
    fail "remove ran without --yes"
fi

if "${MANAGE_SCRIPT}" push --host test.example.com --seats 2 --source "${TEST_ROOT}/README.md" \
    --path ../etc --dry-run >/dev/null 2>&1; then
    fail "unsafe management path was accepted"
fi

if "${MANAGE_SCRIPT}" push --host test.example.com --seats 2 --source "${TEST_ROOT}/README.md" \
    --path lab-01 --transport tunnel --dry-run >/dev/null 2>&1; then
    fail "invalid transport was accepted"
fi

userdata_size=$({
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' "export WORKSTATION_NAME='test-seats'"
    printf '%s\n' "export TERMFLEET_ENDPOINT=''"
    printf '%s\n' "export SEAT_COUNT='100'"
    printf '\n'
    tail -n +2 "${TEST_ROOT}/src/userdata.sh"
} | wc -c)

if [ "${userdata_size}" -gt 16384 ]; then
    fail "generated EC2 user data exceeds 16 KB (${userdata_size} bytes)"
fi

echo "PASS: offline CLI and file-management tests"
