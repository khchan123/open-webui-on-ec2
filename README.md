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

Most models route through the standard Bedrock Converse path (`bedrock/...`) using
the instance IAM role.

### GPT-5.6 (bedrock-mantle)

The **GPT-5.6** models (`gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`) run on the
newer `bedrock-mantle` endpoint (us-east-1, Responses API only) and require a
**Bedrock API key** rather than the IAM role. Set `BEDROCK_MANTLE_API_KEY` in
`/mnt/app/.env` on the instance to enable them; leave it blank to disable them.

Use a **long-term** Bedrock API key (tied to an IAM user, no expiry until revoked),
not a short-term one. Short-term keys embed a presigned signature that expires
(≤12h), and the proxy will fail with `invalid_api_key: Signature expired ...` once
it lapses. After updating the key:

```bash
# on the EC2 instance
sed -i 's|^BEDROCK_MANTLE_API_KEY=.*|BEDROCK_MANTLE_API_KEY=<key>|' /mnt/app/.env
cd /mnt/app && docker compose up -d litellm
```

### Data-retention opt-in (Fable 5 / Mythos 5)

Claude **Fable 5** and **Mythos 5** require the account's Bedrock data-retention
mode to be `provider_data_share` — their only `allowed_modes` value. Under the
default `inherit`/`default` mode, requests are rejected with
`data retention mode 'default' is not available for this model`. Opting in means
prompts and completions are shared with Anthropic and retained up to 30 days.

The mode is set **per region** (not truly account-global) via the Bedrock control
plane, signed with IAM credentials that have `bedrock:PutAccountDataRetention`
(the deploy user, not the read-only instance role). Because these models use the
`global.` inference profile, which can route to any region, set the mode in every
region requests may land in:

```bash
for r in us-east-1 us-west-2 ap-northeast-1 eu-west-1; do
  curl -s -X PUT "https://bedrock.$r.amazonaws.com/data-retention" \
    --aws-sigv4 "aws:amz:$r:bedrock" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
    -H "Content-Type: application/json" -d '{"mode":"provider_data_share"}'
done
```

Check the current mode by swapping `PUT`/`-d ...` for `GET`.

## WAF Rules

The WAF includes the Core Rule Set (with SizeRestrictions_BODY excluded) and IP rate limiting (30k requests/5min). IP Reputation and Anonymous IP lists are enabled by default but can be disabled via `EnableNonCoreWAFRules=false` for CloudFront free plan compatibility.
