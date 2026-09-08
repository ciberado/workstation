#!/bin/bash

# Read-only AWS checks needed before running tests/test_e2e.sh.
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REGION="${1:-${AWS_DEFAULT_REGION:-us-east-1}}"

for required_command in aws jq; do
    command -v "${required_command}" >/dev/null 2>&1 || {
        echo "FAIL: required command is not installed: ${required_command}" >&2
        exit 1
    }
done

identity=$(aws sts get-caller-identity --output json)
vpc_id=$(aws ec2 describe-vpcs --region "${TEST_REGION}" \
    --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
ami_id=$(aws ec2 describe-images --region "${TEST_REGION}" --owners 099720109477 \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)

if [ -z "${vpc_id}" ] || [ "${vpc_id}" = "None" ]; then
    echo "FAIL: no default VPC in ${TEST_REGION}" >&2
    exit 1
fi

if [ -z "${ami_id}" ] || [ "${ami_id}" = "None" ]; then
    echo "FAIL: no Ubuntu 24.04 AMI found in ${TEST_REGION}" >&2
    exit 1
fi

"${TEST_ROOT}/src/launch.sh" --workstation-name preflight-test --region "${TEST_REGION}" \
    --seats 2 --dry >/dev/null

echo "PASS: AWS preflight"
echo "Identity: ${identity}"
echo "Default VPC: ${vpc_id}"
echo "Ubuntu 24.04 AMI: ${ami_id}"
