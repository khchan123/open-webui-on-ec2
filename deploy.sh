#!/bin/bash
set -euo pipefail

# ============================================================================
# Open WebUI CloudFormation Deployment Script
# Usage: ./deploy.sh              - deploy stack + upload scripts
#        ./deploy.sh --refresh    - also re-download scripts and restart on EC2
#        ./deploy.sh --refresh-only - upload scripts + run on EC2, skip CloudFormation
# ============================================================================

# --- Required: fill these in or set in .env ---
DOMAIN_NAME=""
ACM_CERT_ARN=""

# --- Optional: Hermes WebUI subdomain (covered by ACM_CERT_ARN). Empty = skip. ---
HERMES_DOMAIN_NAME=""

# --- Optional: override defaults ---
STACK_NAME="open-webui"
REGION="ap-east-1"
RESOURCE_PREFIX="open-webui"
INSTANCE_TYPE="t4g.medium"
AZ_SUFFIX="a"
ROOT_VOLUME_SIZE="100"
DATA_VOLUME_SIZE="30"
AWS_PROFILE=""

# Load overrides from .env if present
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

# ============================================================================
# Validation
# ============================================================================
if [[ -z "$DOMAIN_NAME" ]]; then echo "ERROR: DOMAIN_NAME required."; exit 1; fi
if [[ -z "$ACM_CERT_ARN" ]]; then echo "ERROR: ACM_CERT_ARN required."; exit 1; fi

TEMPLATE_FILE="cloudformation.yaml"
if [[ ! -f "$TEMPLATE_FILE" ]]; then echo "ERROR: $TEMPLATE_FILE not found."; exit 1; fi

PROFILE_ARG=""
if [[ -n "$AWS_PROFILE" ]]; then PROFILE_ARG="--profile $AWS_PROFILE"; fi

MODE="${1:-}"
REFRESH_ONLY=false
if [[ "$MODE" == "--refresh-only" ]]; then REFRESH_ONLY=true; fi

# ============================================================================
# Detect admin IP
# ============================================================================
echo "Detecting your public IP..."
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
ADMIN_CIDR="${MY_IP:+${MY_IP}/32}"
echo "Admin CIDR: ${ADMIN_CIDR:-none}"
echo ""

# ============================================================================
# Pre-flight
# ============================================================================
echo "=== Pre-flight ==="
echo "Stack: $STACK_NAME | Region: $REGION | Domain: $DOMAIN_NAME"
echo "Instance: $INSTANCE_TYPE | Prefix: $RESOURCE_PREFIX"
aws sts get-caller-identity --region "$REGION" $PROFILE_ARG
echo ""

if [[ "$REFRESH_ONLY" == "false" ]]; then
  aws cloudformation validate-template --template-body "file://$TEMPLATE_FILE" --region "$REGION" $PROFILE_ARG > /dev/null
  echo "Template valid."
  echo ""

  # ============================================================================
  # Deploy (create or update)
  # ============================================================================
  PARAMS="ParameterKey=ResourcePrefix,ParameterValue=$RESOURCE_PREFIX \
    ParameterKey=AlternateDomainName,ParameterValue=$DOMAIN_NAME \
    ParameterKey=AcmCertificateArn,ParameterValue=$ACM_CERT_ARN \
    ParameterKey=HermesDomainName,ParameterValue=$HERMES_DOMAIN_NAME \
    ParameterKey=InstanceType,ParameterValue=$INSTANCE_TYPE \
    ParameterKey=AvailabilityZoneSuffix,ParameterValue=$AZ_SUFFIX \
    ParameterKey=DataVolumeSize,ParameterValue=$DATA_VOLUME_SIZE \
    ParameterKey=AdminCidr,ParameterValue=$ADMIN_CIDR"

  STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text $PROFILE_ARG 2>/dev/null || echo "DOES_NOT_EXIST")

  # Pin the AMI on updates to the running instance's current image. The template
  # defaults ImageId to the latest AL2023 AMI from SSM; on an update that alias
  # re-resolves to a newer AMI and forces an instance replacement (which fails on
  # the attached data volume and wipes the root disk). Passing the live AMI keeps
  # ImageId unchanged. New stacks pass empty -> template uses SSM latest.
  EC2_IMAGE_ID=""
  if [[ "$STACK_STATUS" != "DOES_NOT_EXIST" ]]; then
    EXISTING_EC2_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
      --query "Stacks[0].Outputs[?OutputKey=='EC2InstanceId'].OutputValue" --output text $PROFILE_ARG 2>/dev/null || echo "")
    if [[ -n "$EXISTING_EC2_ID" && "$EXISTING_EC2_ID" != "None" ]]; then
      EC2_IMAGE_ID=$(aws ec2 describe-instances --instance-ids "$EXISTING_EC2_ID" --region "$REGION" \
        --query "Reservations[0].Instances[0].ImageId" --output text $PROFILE_ARG 2>/dev/null || echo "")
      echo "Pinning EC2 AMI to running instance's image: ${EC2_IMAGE_ID:-<none, will use SSM latest>}"
    fi
  fi
  PARAMS="$PARAMS ParameterKey=Ec2ImageId,ParameterValue=$EC2_IMAGE_ID"

  # Root volume size: NEVER change it on an existing instance via CloudFormation.
  # Ebs.VolumeSize lives in the instance's BlockDeviceMappings, and AWS only allows
  # live-modifying DeleteOnTermination there — changing the size forces a full
  # instance REPLACEMENT (wipes the root disk, fails on the attached data volume).
  # CloudFormation diffs the new parameter against the value it last applied, not the
  # actual disk, so once the root has been grown out-of-band (EBS ModifyVolume +
  # growpart + xfs_growfs) we must keep feeding CloudFormation its previous value or
  # the next deploy would try to "shrink/grow" it and replace the box. New stacks use
  # ROOT_VOLUME_SIZE; grow a live root out-of-band, not through this template.
  if [[ "$STACK_STATUS" == "DOES_NOT_EXIST" ]]; then
    PARAMS="$PARAMS ParameterKey=RootVolumeSize,ParameterValue=$ROOT_VOLUME_SIZE"
  else
    PARAMS="$PARAMS ParameterKey=RootVolumeSize,UsePreviousValue=true"
  fi

  IS_NEW_STACK=false
  if [[ "$STACK_STATUS" == "DOES_NOT_EXIST" ]]; then
    IS_NEW_STACK=true
    echo "Creating stack..."
    aws cloudformation create-stack --template-body "file://$TEMPLATE_FILE" \
      --stack-name "$STACK_NAME" --region "$REGION" --capabilities CAPABILITY_NAMED_IAM \
      --timeout-in-minutes 30 --parameters $PARAMS $PROFILE_ARG
    aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION" $PROFILE_ARG
  else
    echo "Updating stack (status: $STACK_STATUS)..."
    aws cloudformation update-stack --template-body "file://$TEMPLATE_FILE" \
      --stack-name "$STACK_NAME" --region "$REGION" --capabilities CAPABILITY_NAMED_IAM \
      --parameters $PARAMS $PROFILE_ARG
    aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$REGION" $PROFILE_ARG
  fi
fi

# ============================================================================
# Upload scripts to S3
# ============================================================================
SCRIPTS_BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ScriptsBucketName'].OutputValue" --output text $PROFILE_ARG)
echo "Uploading scripts to s3://$SCRIPTS_BUCKET/scripts/ ..."
aws s3 sync ec2-scripts/ "s3://$SCRIPTS_BUCKET/scripts/" --region "$REGION" $PROFILE_ARG

# ============================================================================
# Refresh EC2 via SSM (auto on new stack, or with --refresh flag)
# ============================================================================
if [[ "$REFRESH_ONLY" == "true" || "${IS_NEW_STACK:-false}" == "true" || "$MODE" == "--refresh" ]]; then
  EC2_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='EC2InstanceId'].OutputValue" --output text $PROFILE_ARG)
  echo "Running setup on EC2 $EC2_ID via SSM..."
  COMMAND_ID=$(aws ssm send-command --instance-ids "$EC2_ID" --document-name "AWS-RunShellScript" \
    --parameters "commands=['aws s3 cp s3://${SCRIPTS_BUCKET}/scripts/setup.sh /tmp/setup.sh --region ${REGION}','chmod +x /tmp/setup.sh','/tmp/setup.sh']" \
    --region "$REGION" --output text --query "Command.CommandId" $PROFILE_ARG)
  echo "SSM command sent: $COMMAND_ID"
  echo "Waiting for completion..."
  aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$EC2_ID" --region "$REGION" $PROFILE_ARG 2>/dev/null || true
  STATUS=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$EC2_ID" \
    --region "$REGION" --query "Status" --output text $PROFILE_ARG)
  echo "SSM command status: $STATUS"

  if [[ "$STATUS" != "Success" ]]; then
    echo "ERROR: SSM command failed with status: $STATUS"
    exit 1
  fi
fi

# ============================================================================
# Outputs
# ============================================================================
echo ""
aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs" --output table $PROFILE_ARG
echo ""
echo "Done."
EC2_IP=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='EC2PublicIp'].OutputValue" --output text $PROFILE_ARG)
echo "  Open WebUI: https://$DOMAIN_NAME"
echo "  LiteLLM:    http://$EC2_IP:4000/ui"
if [[ -n "$HERMES_DOMAIN_NAME" ]]; then
  HERMES_CF=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='HermesCloudFrontDomainName'].OutputValue" --output text $PROFILE_ARG)
  echo "  Hermes:     https://$HERMES_DOMAIN_NAME  (CNAME -> $HERMES_CF)"
  echo "  Hermes WebUI login password is managed in the WebUI (Settings), stored hashed on the data volume."
fi

if [[ "${IS_NEW_STACK:-false}" == "true" ]]; then
  echo ""
  echo "⚠️  IMPORTANT: Default LiteLLM master key is 'sk-litellm-master-key'."
  echo "   1. Log in to LiteLLM at http://$EC2_IP:4000/ui"
  echo "   2. Update the master key in /mnt/app/.env on the EC2 instance"
  echo "   3. Run: docker compose down && docker compose up -d  (in /mnt/app)"
fi
