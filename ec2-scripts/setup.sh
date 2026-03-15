#!/bin/bash
set -euxo pipefail

# ============================================================================
# setup.sh - Download scripts from S3, register crontab, run start.sh
# Called via SSM after deploy.sh uploads scripts to S3.
# Assumes Docker and /mnt/app volume are already set up by EC2 UserData.
# ============================================================================

# Resolve S3 bucket and region from instance metadata
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | grep accountId | awk -F'"' '{print $4}')
S3_BUCKET="open-webui-ec2-scripts-${ACCOUNT_ID}-${AWS_REGION}"

# Download scripts from S3
mkdir -p /mnt/app/scripts
aws s3 cp "s3://${S3_BUCKET}/scripts/" /mnt/app/scripts/ --recursive --region "${AWS_REGION}"
chmod +x /mnt/app/scripts/*.sh
chown ec2-user:ec2-user /mnt/app
chown -R ec2-user:ec2-user /mnt/app/scripts

# Register start.sh to run on every reboot (idempotent)
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
FILTERED_CRON=$(echo "$EXISTING_CRON" | grep -v '/mnt/app/scripts/start.sh' || true)
printf '%s\n%s\n' "$FILTERED_CRON" '@reboot sleep 10 && /mnt/app/scripts/start.sh >> /var/log/start.log 2>&1' | crontab -

# Run start.sh
/mnt/app/scripts/start.sh
