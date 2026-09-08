#!/bin/bash

# Opt-in EC2 lifecycle test. It uses Session Manager, not direct TCP/22, so it
# works on networks that block or inspect SSH. It creates billable EC2/EIP
# resources and always attempts teardown.
set -euo pipefail

if [ "${RUN_E2E:-}" != "1" ]; then
    echo "Set RUN_E2E=1 to run this cost-incurring integration test." >&2
    exit 2
fi

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
E2E_MODE="${E2E_MODE:-multi}"
TEST_SEATS="${E2E_SEATS:-2}"
TEST_NAME="e2e-${E2E_MODE}-$(date +%Y%m%d%H%M%S)"
KEY_FILE="${E2E_SSH_KEY:-${HOME}/.ssh/ttyd-key.pem}"
EVIDENCE_DIR="$(mktemp -d)"
LAUNCHED=false

cleanup() {
    if [ "${LAUNCHED}" = true ]; then
        AWS_DEFAULT_REGION="${TEST_REGION}" TERMFLEET_ENDPOINT='' \
            "${TEST_ROOT}/src/destroy.sh" -y "${TEST_NAME}" || true
    fi
    rmdir "${EVIDENCE_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

"${TEST_ROOT}/tests/test_aws_preflight.sh" "${TEST_REGION}"

for required_command in aws session-manager-plugin ssh rsync; do
    command -v "${required_command}" >/dev/null 2>&1 || {
        echo "FAIL: required command is not installed: ${required_command}" >&2
        exit 1
    }
done

case "${E2E_MODE}" in
    multi)
        if ! [[ "${TEST_SEATS}" =~ ^[1-9][0-9]*$ ]]; then
            echo "FAIL: E2E_SEATS must be a positive whole number" >&2
            exit 1
        fi
        launch_options=(--seats "${TEST_SEATS}")
        ;;
    autologin)
        launch_options=()
        ;;
    *)
        echo "FAIL: E2E_MODE must be multi or autologin" >&2
        exit 1
        ;;
esac

TERMFLEET_ENDPOINT='' "${TEST_ROOT}/src/launch.sh" --workstation-name "${TEST_NAME}" \
    --region "${TEST_REGION}" --size small "${launch_options[@]}"
LAUNCHED=true

instance_id=$(aws ec2 describe-instances --region "${TEST_REGION}" \
    --filters "Name=tag:Name,Values=${TEST_NAME}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
public_host=$(aws ec2 describe-instances --region "${TEST_REGION}" --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [ ! -f "${KEY_FILE}" ]; then
    echo "FAIL: expected SSH key not found: ${KEY_FILE}" >&2
    exit 1
fi

for attempt in $(seq 1 60); do
    ssm_status=$(aws ssm describe-instance-information --region "${TEST_REGION}" \
        --filters "Key=InstanceIds,Values=${instance_id}" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
    if [ "${ssm_status}" = "Online" ]; then
        break
    fi
    if [ "${attempt}" = 60 ]; then
        echo "FAIL: instance did not become an SSM managed node within 20 minutes" >&2
        exit 1
    fi
    sleep 20
done

ssm_ssh() {
    local attempt

    for attempt in $(seq 1 12); do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o "UserKnownHostsFile=${EVIDENCE_DIR}/known_hosts" -i "${KEY_FILE}" \
            -o "ProxyCommand=aws ssm start-session --region ${TEST_REGION} --target ${instance_id} --document-name AWS-StartSSHSession --parameters portNumber=22" \
            "ubuntu@${public_host}" "$@"; then
            return 0
        fi
        if [ "${attempt}" != 12 ]; then
            echo "Waiting for Session Manager to reconnect (${attempt}/12)..." >&2
            sleep 10
        fi
    done

    echo "FAIL: Session Manager did not remain available" >&2
    return 1
}

ssm_ssh 'sudo cloud-init status --wait >/dev/null'

if [ "${E2E_MODE}" = "autologin" ]; then
    ssm_ssh 'sudo test ! -e /etc/workstation-seats && sudo test -f /home/ubuntu/.tmux.conf && sudo systemctl cat ttyd | grep -Fq "/bin/su - ubuntu"'
else
    ssm_ssh "sudo test \"\$(cat /etc/workstation-seats)\" = \"SEAT_COUNT=${TEST_SEATS}\""
    for seat_number in $(seq 1 "${TEST_SEATS}"); do
        ssm_ssh "getent passwd student${seat_number} >/dev/null && id -nG student${seat_number} | grep -qw docker && sudo test -f /home/student${seat_number}/.tmux.conf"
    done
    ssm_ssh 'sudo systemctl cat ttyd | grep -Fq /bin/login'

    "${TEST_ROOT}/src/manage-files.sh" push --host "${public_host}" --key "${KEY_FILE}" \
        --source "${TEST_ROOT}/README.md" --path e2e-material --region "${TEST_REGION}" --transport ssm
    for seat_number in $(seq 1 "${TEST_SEATS}"); do
        ssm_ssh "sudo test -f /home/student${seat_number}/e2e-material/README.md"
    done

    "${TEST_ROOT}/src/manage-files.sh" pull --host "${public_host}" --key "${KEY_FILE}" \
        --path e2e-material --destination "${EVIDENCE_DIR}" --region "${TEST_REGION}" --transport ssm
    for seat_number in $(seq 1 "${TEST_SEATS}"); do
        test -f "${EVIDENCE_DIR}/${public_host}/student${seat_number}/e2e-material/README.md"
    done

    "${TEST_ROOT}/src/manage-files.sh" remove --host "${public_host}" --key "${KEY_FILE}" \
        --path e2e-material --yes --region "${TEST_REGION}" --transport ssm
    for seat_number in $(seq 1 "${TEST_SEATS}"); do
        ssm_ssh "sudo test ! -e /home/student${seat_number}/e2e-material"
    done
fi

echo "PASS: ${E2E_MODE} end-to-end workstation test (${TEST_NAME})"
