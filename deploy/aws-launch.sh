#!/usr/bin/env bash
# Creates one EC2 server for AI Interviewer. Run on your computer, from the project folder,
# after signing in with `aws login`:
#   REGION=ap-south-1 bash deploy/aws-launch.sh
# Creates: an SSH key pair, a security group, one Ubuntu 24.04 Arm instance and an Elastic IP.
set -euo pipefail

REGION="${REGION:-$(aws configure get region 2>/dev/null || true)}"
: "${REGION:?Set REGION first, for example: REGION=ap-south-1 bash deploy/aws-launch.sh}"
export AWS_REGION="$REGION"
NAME="${NAME:-ai-interviewer}"
TYPE="${INSTANCE_TYPE:-t4g.micro}"
KEY_FILE="$HOME/.ssh/${NAME}.pem"

EXISTING=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$EXISTING" ]; then
  echo "A server named $NAME already exists in $REGION: $EXISTING. Nothing was created."
  exit 1
fi

MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
AMI=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC" = "None" ]; then
  echo "No default VPC in $REGION. Create one with: aws ec2 create-default-vpc"
  exit 1
fi

# SSH key pair, saved only on this computer.
if [ ! -f "$KEY_FILE" ]; then
  if aws ec2 describe-key-pairs --key-names "$NAME" >/dev/null 2>&1; then
    echo "Key pair $NAME exists in AWS but $KEY_FILE is missing."
    echo "Remove the old one with: aws ec2 delete-key-pair --key-name $NAME, then run this again."
    exit 1
  fi
  mkdir -p "$HOME/.ssh"
  (umask 077; aws ec2 create-key-pair --key-name "$NAME" --key-type ed25519 \
    --query KeyMaterial --output text > "$KEY_FILE")
  echo "Saved SSH key to $KEY_FILE"
fi

# Firewall: web traffic from anywhere, SSH only from your current IP.
SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$NAME" "Name=vpc-id,Values=$VPC" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = "None" ]; then
  SG=$(aws ec2 create-security-group --group-name "$NAME" --vpc-id "$VPC" \
    --description "AI Interviewer web server" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32}]" >/dev/null
  echo "Created security group $SG (SSH allowed from $MY_IP only)"
fi

# The server: Ubuntu 24.04 on Graviton, encrypted 20 GB disk, IMDSv2 required,
# standard CPU credits so there are no surprise burst charges.
IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$TYPE" --key-name "$NAME" \
  --security-group-ids "$SG" \
  --credit-specification CpuCredits=standard \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","Encrypted":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "Launching $IID ($TYPE)..."
aws ec2 wait instance-running --instance-ids "$IID"

# A fixed public IP, so the web address doesn't change if the server restarts.
ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME}]" \
  --query AllocationId --output text)
aws ec2 associate-address --instance-id "$IID" --allocation-id "$ALLOC" >/dev/null
IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].PublicIp' --output text)
DOMAIN="${IP//./-}.sslip.io"

cat <<EOF

Server is running.
  Instance:   $IID ($REGION)
  Public IP:  $IP
  Web address (after setup): https://$DOMAIN

Next steps (from the project folder, give the server a minute to boot first):
  1. Copy the app:
     rsync -az --exclude .venv --exclude __pycache__ --exclude .DS_Store -e "ssh -i $KEY_FILE -o StrictHostKeyChecking=accept-new" ./ ubuntu@$IP:~/app/
  2. Install and start it:
     ssh -i $KEY_FILE ubuntu@$IP "bash ~/app/deploy/server-setup.sh $DOMAIN"
  3. In Supabase -> Authentication -> URL Configuration, set Site URL to https://$DOMAIN
     and add https://$DOMAIN/** to Redirect URLs.
EOF
