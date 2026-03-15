# Open WebUI on AWS

Single-stack CloudFormation deployment of [Open WebUI](https://github.com/open-webui/open-webui) + [LiteLLM](https://github.com/BerriAI/litellm) proxy backed by Amazon Bedrock.

## Architecture

CloudFront → EC2 (Open WebUI :80) → LiteLLM (:4000) → Amazon Bedrock

- **CloudFront** with custom domain, ACM SSL, WAF (Core Rule Set + rate limiting)
- **EC2** (t4g.medium ARM, AL2023) in a public subnet with Elastic IP
- **Docker Compose** running Open WebUI, LiteLLM, PostgreSQL, Prometheus
- **Persistent data volume** (gp3, retained on stack delete) at `/mnt/app`
- **WAF** created in us-east-1 via Lambda custom resource (CloudFront scope requirement)

## Prerequisites

- AWS CLI configured with appropriate credentials
- ACM certificate in `us-east-1` for your domain
- DNS access to create a CNAME record

## Configuration

Copy `.env.example` or create `.env`:

```
AWS_PROFILE=your-profile
DOMAIN_NAME=chat.example.com
ACM_CERT_ARN=arn:aws:acm:us-east-1:123456789012:certificate/abc-123
```

Optional overrides (defaults shown):

```
STACK_NAME=open-webui
REGION=ap-east-1
RESOURCE_PREFIX=open-webui
INSTANCE_TYPE=t4g.medium
ROOT_VOLUME_SIZE=30
DATA_VOLUME_SIZE=30
```

## Deploy

```bash
./deploy.sh              # Create/update stack + upload scripts
./deploy.sh --refresh    # Also restart services on EC2 via SSM
./deploy.sh --refresh-only  # Skip CloudFormation, just upload + restart
```

On first deploy, the script automatically uploads ec2-scripts to S3 and triggers setup on the EC2 via SSM.

After deploy, point your DNS CNAME to the CloudFront domain shown in the output.

## EC2 Scripts

| File | Purpose |
|------|---------|
| `setup.sh` | Downloads scripts from S3, registers crontab, runs start.sh |
| `start.sh` | Starts all containers via docker compose (idempotent) |
| `docker-compose.yaml` | LiteLLM + PostgreSQL + Prometheus + Open WebUI |
| `litellm-config.yaml` | Bedrock model definitions |
| `prometheus.yml` | Metrics scraping config |

## Bedrock Models

Edit `ec2-scripts/litellm-config.yaml` to add/remove models. After changes:

```bash
./deploy.sh --refresh
```

## WAF Rules

The WAF includes the Core Rule Set (with SizeRestrictions_BODY excluded) and IP rate limiting (30k requests/5min). IP Reputation and Anonymous IP lists are enabled by default but can be disabled via `EnableNonCoreWAFRules=false` for CloudFront free plan compatibility.
