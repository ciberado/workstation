#!/bin/bash

# Destroy EC2 instance and free all associated resources
# Usage: ./destroy.sh <workstation_name>
#
# This script will:
# - Delete DNS registration from Termfleet
# - Disassociate and release the Elastic IP
# - Terminate the EC2 instance
#
# Example:
#   ./destroy.sh desk1

set -e

# Disable AWS CLI pager to prevent interactive pauses
export AWS_PAGER=""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
REGION="us-east-1"

# Workstation name is MANDATORY
if [ -z "$1" ]; then
    echo "ERROR: Workstation name is required"
    echo "Usage: $0 <workstation_name>"
    echo ""
    echo "Example:"
    echo "  $0 desk1"
    exit 1
fi

WORKSTATION_NAME="$1"
TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-https://termfleet.aprender.cloud}"

# Validate workstation name
if ! echo "${WORKSTATION_NAME}" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]$'; then
    echo "ERROR: Invalid workstation name '${WORKSTATION_NAME}'"
    echo "Name must:"
    echo "  - Be 3-63 characters long"
    echo "  - Start and end with alphanumeric character"
    echo "  - Contain only alphanumeric characters and hyphens"
    exit 1
fi

echo "======================================"
echo "DESTROY WORKSTATION: ${WORKSTATION_NAME}"
echo "======================================"
echo "Termfleet endpoint: ${TERMFLEET_ENDPOINT}"
echo ""
echo "WARNING: This will permanently destroy:"
echo "  - EC2 instance"
echo "  - Elastic IP"
echo "  - DNS registration"
echo "  - All data on the instance"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "${CONFIRM}" != "yes" ]; then
    echo "Destroy cancelled."
    exit 0
fi

echo ""
TAG_NAME="${WORKSTATION_NAME}"

# =================================================================
# Step 1: Find the instance
# =================================================================

echo "Step 1: Looking for instance with name: ${TAG_NAME}"
EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --region ${REGION} \
    --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0]' \
    --output json 2>/dev/null || echo "{}")

if [ "${EXISTING_INSTANCE}" = "{}" ] || [ "$(echo ${EXISTING_INSTANCE} | jq -r '.InstanceId')" = "null" ]; then
    echo "No instance found with name: ${TAG_NAME}"
    INSTANCE_ID=""
else
    INSTANCE_ID=$(echo ${EXISTING_INSTANCE} | jq -r '.InstanceId')
    INSTANCE_STATE=$(echo ${EXISTING_INSTANCE} | jq -r '.State.Name')
    echo "Found instance: ${INSTANCE_ID} (state: ${INSTANCE_STATE})"
fi

# =================================================================
# Step 2: Delete DNS registration from Termfleet
# =================================================================

echo ""
echo "Step 2: Deleting DNS registration from Termfleet..."
DELETE_RESPONSE=$(curl -sf -X DELETE "${TERMFLEET_ENDPOINT}/api/workstations/${WORKSTATION_NAME}" 2>/dev/null || echo "")

if [ -n "${DELETE_RESPONSE}" ]; then
    DELETE_SUCCESS=$(echo "${DELETE_RESPONSE}" | jq -r '.success' 2>/dev/null || echo "false")
    if [ "${DELETE_SUCCESS}" = "true" ]; then
        echo "✓ DNS registration deleted from Termfleet"
    else
        echo "⚠ DNS registration not found or already deleted"
    fi
else
    echo "⚠ Could not connect to Termfleet (may be offline)"
fi

# =================================================================
# Step 3: Find and release Elastic IP
# =================================================================

echo ""
echo "Step 3: Looking for Elastic IP..."
EIP_TAG_NAME="workstation-eip-${WORKSTATION_NAME}"
EIP_ALLOCATION=$(aws ec2 describe-addresses \
    --region ${REGION} \
    --filters "Name=tag:Name,Values=${EIP_TAG_NAME}" \
    --query 'Addresses[0].AllocationId' \
    --output text 2>/dev/null || echo "None")

if [ "${EIP_ALLOCATION}" = "None" ] || [ -z "${EIP_ALLOCATION}" ]; then
    echo "No Elastic IP found with tag: ${EIP_TAG_NAME}"
else
    echo "Found Elastic IP: ${EIP_ALLOCATION}"
    
    # Check if it's associated
    ASSOCIATION_ID=$(aws ec2 describe-addresses \
        --region ${REGION} \
        --allocation-ids ${EIP_ALLOCATION} \
        --query 'Addresses[0].AssociationId' \
        --output text 2>/dev/null || echo "None")
    
    if [ "${ASSOCIATION_ID}" != "None" ] && [ -n "${ASSOCIATION_ID}" ]; then
        echo "Disassociating Elastic IP..."
        aws ec2 disassociate-address \
            --region ${REGION} \
            --association-id ${ASSOCIATION_ID}
        echo "✓ Elastic IP disassociated"
    fi
    
    echo "Releasing Elastic IP..."
    aws ec2 release-address \
        --region ${REGION} \
        --allocation-id ${EIP_ALLOCATION}
    echo "✓ Elastic IP released"
fi

# =================================================================
# Step 4: Terminate instance
# =================================================================

if [ -n "${INSTANCE_ID}" ]; then
    echo ""
    echo "Step 4: Terminating instance..."
    
    # Check if instance is already terminated
    if [ "${INSTANCE_STATE}" = "terminated" ]; then
        echo "Instance is already terminated"
    else
        aws ec2 terminate-instances \
            --region ${REGION} \
            --instance-ids ${INSTANCE_ID} \
            --output text > /dev/null
        
        echo "✓ Termination initiated for instance: ${INSTANCE_ID}"
        echo ""
        echo "Note: Instance will be fully terminated in a few minutes."
        echo "      You can check status with:"
        echo "      aws ec2 describe-instances --region ${REGION} --instance-ids ${INSTANCE_ID}"
    fi
else
    echo ""
    echo "Step 4: No instance to terminate"
fi

# =================================================================
# Summary
# =================================================================

echo ""
echo "======================================"
echo "DESTRUCTION COMPLETE"
echo "======================================"
echo "Workstation: ${WORKSTATION_NAME}"
echo ""
echo "Destroyed resources:"
if [ -n "${DELETE_RESPONSE}" ] && [ "${DELETE_SUCCESS}" = "true" ]; then
    echo "  ✓ DNS registration (Termfleet)"
else
    echo "  - DNS registration (not found or offline)"
fi
if [ "${EIP_ALLOCATION}" != "None" ] && [ -n "${EIP_ALLOCATION}" ]; then
    echo "  ✓ Elastic IP (${EIP_ALLOCATION})"
else
    echo "  - Elastic IP (not found)"
fi
if [ -n "${INSTANCE_ID}" ]; then
    echo "  ✓ EC2 instance (${INSTANCE_ID})"
else
    echo "  - EC2 instance (not found)"
fi
echo ""
echo "The workstation '${WORKSTATION_NAME}' has been destroyed."
echo "======================================"
