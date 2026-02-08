#!/bin/bash

# Launch EC2 instance with ttyd and Caddy setup
# Usage: ./launch.sh <iam_role_name>
# Example: ./launch.sh LabRole

set -e

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
    echo "Usage: $0 <iam_role_name>"
    echo "Example: $0 LabRole"
    exit 1
fi

ROLE_NAME="$1"
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

echo "Finding latest Ubuntu 22.04 LTS AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region ${REGION} \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
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

# Launch instance
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
    --user-data file://${SCRIPT_DIR}/userdata.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=workstation}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance launched: ${INSTANCE_ID}"
echo "Waiting for instance to start..."

# Wait for instance to be running
aws ec2 wait instance-running \
    --region ${REGION} \
    --instance-ids ${INSTANCE_ID}

# Get instance details
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
echo "Instance launched successfully!"
echo "======================================"
echo "Instance ID: ${INSTANCE_ID}"
echo "Public DNS: ${PUBLIC_DNS}"
echo "Public IP: ${PUBLIC_IP}"
if [ "${IAM_ROLE}" != "None" ]; then
    echo "IAM Role: ${IAM_ROLE}"
else
    echo "IAM Role: Not attached"
fi
echo ""
echo "SSH Access:"
if [ -f "${KEY_FILE}" ]; then
    echo "  ssh -i ${KEY_FILE} ubuntu@${PUBLIC_DNS}"
else
    echo "  ssh -i <path-to-${KEY_NAME}.pem> ubuntu@${PUBLIC_DNS}"
fi
echo ""
echo "Web Terminal (after setup completes, ~5-10 minutes):"
echo "  https://${PUBLIC_DNS}"
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
