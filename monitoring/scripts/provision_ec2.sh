#!/usr/bin/env bash
set -euo pipefail

# Provision two EC2 instances (monitoring + target) and update monitoring/inventory.ini
# Run this in WSL Ubuntu. Assumes AWS CLI is configured (aws configure) or env vars are set.

KEY_NAME_DEFAULT="ansible"
KEY_DIR="$HOME/keys"
KEY_PATH="$KEY_DIR/${KEY_NAME_DEFAULT}.pem"
SG_NAME_DEFAULT="monitoring-sg"
INSTANCE_TYPE_DEFAULT="t3.micro"
REGION_DEFAULT="${AWS_DEFAULT_REGION:-us-east-2}"

read -r -p "AWS region [${REGION_DEFAULT}]: " REGION
REGION=${REGION:-$REGION_DEFAULT}

read -r -p "Key pair name [${KEY_NAME_DEFAULT}]: " KEY_NAME
KEY_NAME=${KEY_NAME:-$KEY_NAME_DEFAULT}

read -r -p "Key path [${KEY_DIR}/${KEY_NAME}.pem]: " KEY_PATH_INPUT
if [ -n "$KEY_PATH_INPUT" ]; then
  KEY_PATH="$KEY_PATH_INPUT"
else
  KEY_PATH="$KEY_DIR/${KEY_NAME}.pem"
fi

read -r -p "Security group name [${SG_NAME_DEFAULT}]: " SG_NAME
SG_NAME=${SG_NAME:-$SG_NAME_DEFAULT}

read -r -p "Instance type [${INSTANCE_TYPE_DEFAULT}]: " INSTANCE_TYPE
INSTANCE_TYPE=${INSTANCE_TYPE:-$INSTANCE_TYPE_DEFAULT}

echo "Using region: $REGION"
aws --version >/dev/null 2>&1 || { echo "AWS CLI not found. Install and configure it first."; exit 1; }

echo "Checking AWS credentials..."
if ! aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  echo "AWS CLI not configured or credentials invalid. Run 'aws configure' or export env vars.";
  exit 1
fi

mkdir -p "$KEY_DIR"

echo "Creating or reusing key pair: $KEY_NAME"
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "Key pair $KEY_NAME already exists in region $REGION. Please ensure you have the private key locally at $KEY_PATH or create a new key name.";
else
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$KEY_PATH"
  chmod 600 "$KEY_PATH"
  echo "Saved key to $KEY_PATH"
fi

echo "Creating or locating security group: $SG_NAME"

read -r -p "Subnet ID to launch instances into [press Enter to list available subnets]: " SUBNET_ID
if [ -z "$SUBNET_ID" ]; then
  echo "Available subnets:"
  aws ec2 describe-subnets --region "$REGION" --query 'Subnets[].{SubnetId:SubnetId,VpcId:VpcId,AZ:AvailabilityZone,CIDR:CidrBlock}' --output table
  read -r -p "Enter subnet ID: " SUBNET_ID
fi

if [ -z "$SUBNET_ID" ]; then
  echo "No subnet selected. Aborting."
  exit 1
fi

VPC_ID=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId' --output text)
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "Could not determine VPC for subnet $SUBNET_ID. Aborting."
  exit 1
fi
echo "Using subnet: $SUBNET_ID"
echo "Using VPC: $VPC_ID"

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME" --description "Monitoring stack SG" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
  echo "Created SG: $SG_ID"
else
  echo "Found SG: $SG_ID"
fi

read -r -p "Enter your workstation CIDR for SSH/Grafana/Prometheus access (e.g. 203.0.113.4/32) or press Enter to open only SSH from current IP: " MY_IP_CIDR
if [ -z "$MY_IP_CIDR" ]; then
  # try detect
  CUR_IP=$(curl -s https://checkip.amazonaws.com || true)
  if [ -n "$CUR_IP" ]; then
    MY_IP_CIDR="$CUR_IP/32"
    echo "Detected IP: $MY_IP_CIDR"
  else
    echo "Could not detect IP. Defaulting to 0.0.0.0/0 for demo (NOT recommended)."
    MY_IP_CIDR="0.0.0.0/0"
  fi
fi

echo "Authorizing security group ingress rules (SSH, Grafana, Prometheus, Node Exporter)
SSH/Grafana/Prometheus CIDR: $MY_IP_CIDR"
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP_CIDR" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 3000 --cidr "$MY_IP_CIDR" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 9090 --cidr "$MY_IP_CIDR" >/dev/null 2>&1 || true
# Node exporter: allow from same SG (intra-group)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 9100 --source-group "$SG_ID" >/dev/null 2>&1 || true

echo "Finding latest Ubuntu 22.04 AMI (region: $REGION)"
AMI=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' 'Name=state,Values=available' --query 'Images | sort_by(@,&CreationDate)[-1].ImageId' --output text)
echo "Using AMI: $AMI"

echo "Launching monitoring instance"
MON_RES=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" --count 1 --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=monitoring}]" --associate-public-ip-address)
MON_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Instances"][0]["InstanceId"])' <<< "$MON_RES")

echo "Launching target instance"
TGT_RES=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" --count 1 --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=target}]" --associate-public-ip-address)
TGT_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Instances"][0]["InstanceId"])' <<< "$TGT_RES")

echo "Waiting for instances to be 'running'"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$MON_ID" "$TGT_ID"

MON_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$MON_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
TGT_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$TGT_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "Monitoring public IP: $MON_IP"
echo "Target public IP: $TGT_IP"

INVENTORY_FILE="$(dirname "$0")/../inventory.ini"
INVENTORY_FILE=$(realpath "$INVENTORY_FILE")

if [ ! -f "$INVENTORY_FILE" ]; then
  echo "inventory.ini not found at $INVENTORY_FILE. Aborting."
  exit 1
fi

echo "Backing up inventory: ${INVENTORY_FILE}.bak"
cp "$INVENTORY_FILE" "${INVENTORY_FILE}.bak"

echo "Updating inventory with new public IPs"
sed -i "s/<MONITORING_PUBLIC_IP>/$MON_IP/" "$INVENTORY_FILE" || true
sed -i "s/<TARGET_PUBLIC_IP>/$TGT_IP/" "$INVENTORY_FILE" || true

echo "Ensuring key path in inventory points to $KEY_PATH"
sed -i "s#ansible_ssh_private_key_file=~\/keys\/my-ec2-key.pem#ansible_ssh_private_key_file=$KEY_PATH#" "$INVENTORY_FILE" || true

echo "Done. Inventory updated: $INVENTORY_FILE"

echo "Next steps from WSL:" 
echo "  ssh -i $KEY_PATH ubuntu@$MON_IP 'echo monitoring OK'"
echo "  ssh -i $KEY_PATH ubuntu@$TGT_IP 'echo target OK'"
echo "  cd $(dirname "$0")/.."
echo "  ansible-playbook -i inventory.ini playbook.yml --check"
echo "  ansible-playbook -i inventory.ini playbook.yml"

echo "IMPORTANT: Do not commit $KEY_PATH or AWS credentials to VCS."
