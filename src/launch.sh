#!/bin/bash

# Launch EC2 instance with ttyd and Caddy setup
# Usage: ./launch.sh <iam_role_name> [workstation_name]
# 
# Basic usage (single workstation with AWS hostname):
#   ./launch.sh LabRole
#
# Named workstation with custom domain (Termfleet integration):
#   TERMFLEET_ENDPOINT=https://termfleet.example.com \
#   BASE_DOMAIN=example.com \
#   ./launch.sh LabRole desk1
#
# Note: When using named workstations, TERMFLEET_ENDPOINT and BASE_DOMAIN are required

set -e

# Disable AWS CLI pager to prevent interactive pauses
export AWS_PAGER=""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
REGION="us-east-1"
INSTANCE_TYPE="t3.medium"
VOLUME_SIZE=8
VOLUME_TYPE="gp3"
SECURITY_GROUP_NAME="ttyd-access"
KEY_NAME="ttyd-key"

# Check if IAM role name is provided (mandatory)
if [ -z "$1" ]; then
    echo "ERROR: IAM role name is required"
    echo "Usage: $0 <iam_role_name> [workstation_name]"
    echo "Example: $0 LabRole desk1"
    exit 1
fi

ROLE_NAME="$1"
WORKSTATION_NAME="${2:-}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-}"

# Validate workstation name if provided
if [ -n "${WORKSTATION_NAME}" ]; then
    # Must be alphanumeric with hyphens, 3-63 characters
    if ! echo "${WORKSTATION_NAME}" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]$'; then
        echo "ERROR: Invalid workstation name '${WORKSTATION_NAME}'"
        echo "Name must:"
        echo "  - Be 3-63 characters long"
        echo "  - Start and end with alphanumeric character"
        echo "  - Contain only alphanumeric characters and hyphens"
        exit 1
    fi
    echo "Workstation name: ${WORKSTATION_NAME}"
else
    echo "Workstation name: Will use AWS hostname"
fi

# Validate BASE_DOMAIN if workstation name is provided
if [ -n "${WORKSTATION_NAME}" ] && [ -z "${BASE_DOMAIN}" ]; then
    echo "ERROR: BASE_DOMAIN environment variable must be set when using custom workstation name"
    echo "Example: BASE_DOMAIN=example.com ./launch.sh LabRole desk1"
    exit 1
fi

if [ -n "${BASE_DOMAIN}" ]; then
    echo "Base domain: ${BASE_DOMAIN}"
fi

# Validate TERMFLEET_ENDPOINT if workstation name is provided
if [ -n "${WORKSTATION_NAME}" ] && [ -z "${TERMFLEET_ENDPOINT}" ]; then
    echo "ERROR: TERMFLEET_ENDPOINT environment variable must be set when using custom workstation name"
    echo "Example: TERMFLEET_ENDPOINT=https://termfleet.example.com BASE_DOMAIN=example.com ./launch.sh LabRole desk1"
    exit 1
fi

if [ -n "${TERMFLEET_ENDPOINT}" ]; then
    echo "Termfleet endpoint: ${TERMFLEET_ENDPOINT}"
fi

echo "Will attach IAM role to EC2 instance: ${ROLE_NAME}"
    
    # Check if role exists and has EC2 trust policy
    ROLE_INFO=$(aws iam get-role \
        --role-name ${ROLE_NAME} \
        --query 'Role' \
        --output json 2>/dev/null || echo "{}")
    
    if [ "$ROLE_INFO" = "{}" ]; then
        echo "ERROR: Role ${ROLE_NAME} does not exist."
        exit 1
    fi
    
    echo "Role ${ROLE_NAME} exists. Checking trust policy..."
    
    # Check trust policy allows EC2
    TRUST_POLICY=$(echo ${ROLE_INFO} | jq -r '.AssumeRolePolicyDocument')
    if ! echo ${TRUST_POLICY} | grep -q "ec2.amazonaws.com"; then
        echo "WARNING: Role ${ROLE_NAME} may not have EC2 in its trust policy."
        echo "The instance may not be able to assume this role."
    fi
    
    # Check if instance profile exists
    PROFILE_EXISTS=$(aws iam get-instance-profile \
        --instance-profile-name ${ROLE_NAME} \
        --query 'InstanceProfile.InstanceProfileName' \
        --output text 2>/dev/null || echo "None")
    
    if [ "${PROFILE_EXISTS}" = "None" ] || [ -z "${PROFILE_EXISTS}" ]; then
        echo "Instance profile '${ROLE_NAME}' not found. Creating it..."
        
        # Create instance profile
        aws iam create-instance-profile \
            --instance-profile-name ${ROLE_NAME} 2>/dev/null || echo "Profile may already exist"
        
        # Attach role to instance profile
        aws iam add-role-to-instance-profile \
            --instance-profile-name ${ROLE_NAME} \
            --role-name ${ROLE_NAME} 2>/dev/null || echo "Role may already be attached"
        
        echo "Instance profile created and role attached."
        
        # Wait a bit for the profile to be available
        echo "Waiting for instance profile to propagate..."
        sleep 10
    else
        echo "Using existing instance profile: ${ROLE_NAME}"
    fi
    
    INSTANCE_PROFILE_ARG="--iam-instance-profile Name=${ROLE_NAME}"

echo "Finding latest Ubuntu 24.04 LTS AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region ${REGION} \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

echo "Using AMI: ${AMI_ID}"

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs \
    --region ${REGION} \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text)

echo "Using VPC: ${VPC_ID}"

# Check if security group exists, create if not
SG_ID=$(aws ec2 describe-security-groups \
    --region ${REGION} \
    --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    2>/dev/null || echo "None")

if [ "${SG_ID}" = "None" ] || [ -z "${SG_ID}" ]; then
    echo "Creating security group..."
    SG_ID=$(aws ec2 create-security-group \
        --region ${REGION} \
        --group-name ${SECURITY_GROUP_NAME} \
        --description "Security group for ttyd access with HTTPS" \
        --vpc-id ${VPC_ID} \
        --query 'GroupId' \
        --output text)
    
    # Add rules for SSH, HTTP, and HTTPS
    aws ec2 authorize-security-group-ingress \
        --region ${REGION} \
        --group-id ${SG_ID} \
        --ip-permissions \
        IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0,Description="SSH"}]' \
        IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0,Description="HTTP"}]' \
        IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0,Description="HTTPS"}]'
    
    echo "Security group created: ${SG_ID}"
else
    echo "Using existing security group: ${SG_ID}"
fi

# Check if key pair exists, create if not
KEY_FILE="${PWD}/${KEY_NAME}.pem"
KEY_EXISTS=$(aws ec2 describe-key-pairs \
    --region ${REGION} \
    --key-names ${KEY_NAME} \
    --query 'KeyPairs[0].KeyName' \
    --output text \
    2>/dev/null || echo "None")

if [ "${KEY_EXISTS}" = "None" ] || [ -z "${KEY_EXISTS}" ]; then
    echo "Creating key pair..."
    aws ec2 create-key-pair \
        --region ${REGION} \
        --key-name ${KEY_NAME} \
        --query 'KeyMaterial' \
        --output text \
        > "${KEY_FILE}"
    chmod 400 "${KEY_FILE}"
    echo "Key pair created and saved to ${KEY_FILE}"
else
    echo "Using existing key pair: ${KEY_NAME}"
    if [ ! -f "${KEY_FILE}" ]; then
        echo "WARNING: Key pair exists in AWS but ${KEY_FILE} not found locally."
        echo "You may need to use an existing key file to SSH."
    fi
fi

# Prepare userdata with workstation name and base domain if provided
if [ -n "${WORKSTATION_NAME}" ]; then
    echo "Preparing userdata with workstation name: ${WORKSTATION_NAME}"
    USERDATA_FILE="${SCRIPT_DIR}/.userdata.tmp"
    # Add environment variables at the beginning of userdata
    {
        echo "#!/bin/bash"
        echo "export WORKSTATION_NAME='${WORKSTATION_NAME}'"
        if [ -n "${BASE_DOMAIN}" ]; then
            echo "export BASE_DOMAIN='${BASE_DOMAIN}'"
        fi
        if [ -n "${TERMFLEET_ENDPOINT}" ]; then
            echo "export TERMFLEET_ENDPOINT='${TERMFLEET_ENDPOINT}'"
        fi
        echo ""
        tail -n +2 "${SCRIPT_DIR}/userdata.sh"  # Skip shebang from original
    } > "${USERDATA_FILE}"
    USERDATA_ARG="file://${USERDATA_FILE}"
    TAG_NAME="${WORKSTATION_NAME}"
else
    USERDATA_ARG="file://${SCRIPT_DIR}/userdata.sh"
    TAG_NAME="workstation"
fi

# =================================================================
# Check for existing instance with the same name
# If found: start it if stopped, or display info if running
# If not found: launch a new instance
# =================================================================

echo "Checking for existing instance with name: ${TAG_NAME}"
EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --region ${REGION} \
    --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0]' \
    --output json 2>/dev/null || echo "{}")

if [ "${EXISTING_INSTANCE}" != "{}" ] && [ "$(echo ${EXISTING_INSTANCE} | jq -r '.InstanceId')" != "null" ]; then
    INSTANCE_ID=$(echo ${EXISTING_INSTANCE} | jq -r '.InstanceId')
    INSTANCE_STATE=$(echo ${EXISTING_INSTANCE} | jq -r '.State.Name')
    
    echo "Found existing instance: ${INSTANCE_ID} (state: ${INSTANCE_STATE})"
    
    case "${INSTANCE_STATE}" in
        running)
            echo "Instance is already running!"
            ;;
        pending)
            echo "Instance is starting..."
            aws ec2 wait instance-running \
                --region ${REGION} \
                --instance-ids ${INSTANCE_ID}
            echo "Instance is now running!"
            ;;
        stopped)
            echo "Instance is stopped. Starting it now..."
            aws ec2 start-instances \
                --region ${REGION} \
                --instance-ids ${INSTANCE_ID} \
                --output text > /dev/null
            
            echo "Waiting for instance to start..."
            aws ec2 wait instance-running \
                --region ${REGION} \
                --instance-ids ${INSTANCE_ID}
            echo "Instance started successfully!"
            ;;
        stopping)
            echo "Instance is currently stopping. Waiting for it to stop completely..."
            aws ec2 wait instance-stopped \
                --region ${REGION} \
                --instance-ids ${INSTANCE_ID}
            echo "Instance stopped. Now starting it..."
            aws ec2 start-instances \
                --region ${REGION} \
                --instance-ids ${INSTANCE_ID} \
                --output text > /dev/null
            
            echo "Waiting for instance to start..."
            aws ec2 wait instance-running \
                --region ${REGION} \
                --instance-ids ${INSTANCE_ID}
            echo "Instance started successfully!"
            ;;
        *)
            echo "Unexpected instance state: ${INSTANCE_STATE}"
            exit 1
            ;;
    esac
    
    # Skip to displaying info (jump to after instance launch section)
    REUSING_INSTANCE=true
else
    echo "No existing instance found. Launching new instance..."
    REUSING_INSTANCE=false
fi

# Launch new instance (only if not reusing existing one)
if [ "${REUSING_INSTANCE}" = false ]; then
    echo "Launching instance..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --region ${REGION} \
        --image-id ${AMI_ID} \
        --instance-type ${INSTANCE_TYPE} \
        --key-name ${KEY_NAME} \
        --security-group-ids ${SG_ID} \
        ${INSTANCE_PROFILE_ARG} \
        --metadata-options "HttpTokens=optional,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"${VOLUME_TYPE}\",\"DeleteOnTermination\":true}}]" \
        --user-data "${USERDATA_ARG}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_NAME}}]" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    echo "Instance launched: ${INSTANCE_ID}"
    echo "Waiting for instance to start..."
    
    # Wait for instance to be running
    aws ec2 wait instance-running \
        --region ${REGION} \
        --instance-ids ${INSTANCE_ID}
fi

# Clean up temporary userdata file if created
[ -f "${SCRIPT_DIR}/.userdata.tmp" ] && rm -f "${SCRIPT_DIR}/.userdata.tmp"

# Determine EIP tag name (per-workstation or shared)
if [ -n "${WORKSTATION_NAME}" ]; then
    EIP_TAG_NAME="workstation-eip-${WORKSTATION_NAME}"
    echo "Using per-workstation Elastic IP for: ${WORKSTATION_NAME}"
else
    EIP_TAG_NAME="workstation-eip"
    echo "Using shared Elastic IP (no workstation name specified)"
fi

# Check for existing Elastic IP with tag
echo "Checking for existing Elastic IP tagged as: ${EIP_TAG_NAME}"
EIP_ALLOCATION=$(aws ec2 describe-addresses \
    --region ${REGION} \
    --filters "Name=tag:Name,Values=${EIP_TAG_NAME}" \
    --query 'Addresses[0].AllocationId' \
    --output text 2>/dev/null || echo "None")

if [ "${EIP_ALLOCATION}" = "None" ] || [ -z "${EIP_ALLOCATION}" ]; then
    echo "No existing Elastic IP found. Allocating new one..."
    EIP_ALLOCATION=$(aws ec2 allocate-address \
        --region ${REGION} \
        --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${EIP_TAG_NAME}}]" \
        --query 'AllocationId' \
        --output text)
    echo "Elastic IP allocated: ${EIP_ALLOCATION}"
    NEED_ASSOCIATION=true
else
    echo "Using existing Elastic IP: ${EIP_ALLOCATION}"
    
    # Check if EIP is already associated with this instance
    CURRENT_ASSOCIATION=$(aws ec2 describe-addresses \
        --region ${REGION} \
        --allocation-ids ${EIP_ALLOCATION} \
        --query 'Addresses[0].InstanceId' \
        --output text 2>/dev/null || echo "None")
    
    if [ "${CURRENT_ASSOCIATION}" = "${INSTANCE_ID}" ]; then
        echo "Elastic IP is already associated with this instance"
        NEED_ASSOCIATION=false
    else
        if [ "${CURRENT_ASSOCIATION}" != "None" ] && [ -n "${CURRENT_ASSOCIATION}" ]; then
            echo "Elastic IP is currently associated with different instance: ${CURRENT_ASSOCIATION}"
            echo "Will reassociate to current instance"
        fi
        NEED_ASSOCIATION=true
    fi
fi

# Associate Elastic IP with instance (if needed)
if [ "${NEED_ASSOCIATION}" = true ]; then
    echo "Associating Elastic IP with instance..."
    ASSOCIATION_ID=$(aws ec2 associate-address \
        --region ${REGION} \
        --instance-id ${INSTANCE_ID} \
        --allocation-id ${EIP_ALLOCATION} \
        --query 'AssociationId' \
        --output text)
    echo "Elastic IP associated: ${ASSOCIATION_ID}"
fi

# Get instance details with Elastic IP
INSTANCE_INFO=$(aws ec2 describe-instances \
    --region ${REGION} \
    --instance-ids ${INSTANCE_ID} \
    --query 'Reservations[0].Instances[0]' \
    --output json)

PUBLIC_DNS=$(echo ${INSTANCE_INFO} | jq -r '.PublicDnsName')
PUBLIC_IP=$(echo ${INSTANCE_INFO} | jq -r '.PublicIpAddress')
IAM_ROLE=$(echo ${INSTANCE_INFO} | jq -r '.IamInstanceProfile.Arn // "None"')

echo "Waiting for SSH to be available..."
aws ec2 wait instance-status-ok \
    --region ${REGION} \
    --instance-ids ${INSTANCE_ID} 2>/dev/null || echo "Note: Instance may still be initializing"

echo ""
echo "======================================"
if [ "${REUSING_INSTANCE}" = true ]; then
    echo "Instance ready!"
else
    echo "Instance launched successfully!"
fi
echo "======================================"
echo "Instance ID: ${INSTANCE_ID}"
echo "Public DNS: ${PUBLIC_DNS}"
echo "Public IP (Elastic): ${PUBLIC_IP}"
if [ "${IAM_ROLE}" != "None" ]; then
    echo "IAM Role: ${IAM_ROLE}"
else
    echo "IAM Role: Not attached"
fi
echo ""
if [ -n "${WORKSTATION_NAME}" ]; then
    echo "Elastic IP tagged as '${EIP_TAG_NAME}' (dedicated to this workstation)"
    if [ "${REUSING_INSTANCE}" = true ]; then
        echo "Instance and IP are persistent - safe to stop/start"
    else
        echo "This IP will be reused when you restart '${WORKSTATION_NAME}'"
    fi
else
    echo "Elastic IP tagged as 'workstation-eip' (shared)"
    echo "Warning: Launching another instance will move this IP"
fi
echo ""
echo "SSH Access:"
if [ -f "${KEY_FILE}" ]; then
    echo "  ssh -i ${KEY_FILE} ubuntu@${PUBLIC_DNS}"
else
    echo "  ssh -i <path-to-${KEY_NAME}.pem> ubuntu@${PUBLIC_DNS}"
fi
echo ""
if [ "${REUSING_INSTANCE}" = true ]; then
    echo "Web Terminal (should be available immediately):"
else
    echo "Web Terminal (after setup completes, ~5-10 minutes):"
fi
if [ -n "${WORKSTATION_NAME}" ] && [ -n "${BASE_DOMAIN}" ]; then
    echo "  https://${WORKSTATION_NAME}.${BASE_DOMAIN}"
    echo "  (fallback: https://${PUBLIC_DNS})"
else
    echo "  https://${PUBLIC_DNS}"
fi
echo ""
echo "Ubuntu password: arch@1234"
echo ""
echo "Note: Wait a few minutes for user-data script to complete."
echo "      You can check progress with:"
if [ -f "${KEY_FILE}" ]; then
    echo "      ssh -i ${KEY_FILE} ubuntu@${PUBLIC_DNS} 'tail -f /var/log/cloud-init-output.log'"
else
    echo "      ssh -i <path-to-${KEY_NAME}.pem> ubuntu@${PUBLIC_DNS} 'tail -f /var/log/cloud-init-output.log'"
fi
echo "======================================"
