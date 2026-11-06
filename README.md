# BrightPath To-Do: a small app, deployed properly on AWS

A to-do list (Flask + PostgreSQL) running on a Linux EC2 instance, with the database on Amazon RDS. The app is intentionally tiny; the point of the repo is **how it is deployed and run**: infrastructure as code, keyless CI/CD, HTTPS, least-privilege networking, monitoring and a hard look at cost.

| | |
|---|---|
| **Live app** | `https://<elastic-ip-with-dashes>.sslip.io` ← *replace with the `app_url` Terraform prints* |
| **Health check** | `<live app>/health` |
| **Demo video** | *link* |

---

## What it does

- `GET /`: list to-dos, add one, tick it off, delete it. Every action is a real `INSERT` / `UPDATE` / `DELETE` against PostgreSQL, and the page is read back from the database.
- `GET /health`: JSON that shows whether the app **and** its database connection work:

```json
{
  "status": "ok",
  "app": "ok",
  "database": { "ok": true, "latency_ms": 1.8, "todo_count": 3 },
  "version": "3f9c2ab",
  "instance": "i-0abc123def4567890"
}
```

It returns **200** when healthy and **503** when the database is unreachable (`"status": "degraded"`). The app process keeps running in that case, so it can *report* the outage instead of crash-looping. `version` is the git commit that is live, and `instance` is the EC2 instance serving it, which makes deploys easy to verify.

---

## Architecture

### How a request travels

![Request path](docs/architecture.png)

1. The browser looks up `<ip>.sslip.io`. [sslip.io](https://sslip.io) is a free public DNS service that resolves a name to the IP inside it, so the app gets a real hostname (and a real TLS certificate) without buying a domain.
2. HTTPS hits the **Elastic IP** → **Internet Gateway** → the **EC2 instance**, whose security group allows only ports 80 and 443.
3. **Caddy** terminates TLS (certificate from Let's Encrypt, auto-renewed) and redirects port 80 to HTTPS.
4. Caddy proxies to the **Flask/Gunicorn** container over the private Docker network. Port 8000 is never exposed on the host.
5. The app queries **RDS PostgreSQL** in a private subnet over TLS. The DB security group only accepts 5432 *from the web server's security group*.
6–8. Rows come back, the app renders HTML/JSON, and Caddy returns it to the browser over HTTPS.

### How code gets deployed (and how I'd find out something broke)

![Deploy flow](docs/deploy-flow.png)

On every push to `main`, GitHub Actions:

1. runs the tests against a real Postgres service container
2. builds the Docker image
3. pushes it to **ECR**, tagged with the git SHA (tags are immutable)
4. calls **SSM Run Command** on the instance. `deploy/deploy.sh` checks out that SHA, reads config from **SSM Parameter Store**, pulls the image, runs `docker compose up --wait` (which waits for the container health check) and **rolls back** to the previous image if the new one never becomes healthy
5. smoke-tests the public `/health` and checks that it reports the *new* version

AWS access comes from **GitHub OIDC**: the workflow gets 1-hour credentials for a role that only trusts `main` of this repo. There are no AWS keys in GitHub and no SSH keys anywhere.

Diagram sources: [`docs/architecture.mmd`](docs/architecture.mmd), [`docs/deploy-flow.mmd`](docs/deploy-flow.mmd) (Mermaid).

---

## Main choices and alternatives considered

| Decision | Chose | Considered | Why |
|---|---|---|---|
| **Compute** | EC2 `t3.micro` | `t4g.micro` (Graviton/ARM), `t2.micro` | `t3.micro` is Free Tier-eligible for **both** older accounts and accounts created after 15 July 2025. `t4g` is cheaper per hour but would need ARM/multi-arch image builds; `t2` is older and not eligible on new accounts. CPU credits are set to `standard`, so a busy CPU is throttled rather than billed. |
| **Linux distro** | Amazon Linux 2023 | Ubuntu 24.04 | AL2023 ships with the SSM agent and AWS CLI, is tuned for EC2 and is supported by AWS. Ubuntu would work just as well; AL2023 meant less bootstrap code. |
| **Database** | RDS PostgreSQL 16 `db.t3.micro` | Postgres in a container on the same EC2; DynamoDB | Managed backups, patching, encryption and a private endpoint. Running Postgres on the same 1 GB box would tie the data to the server's lifecycle and compete for RAM. DynamoDB is always-free, but relational SQL is closer to a typical SaaS backend and easier to reason about. |
| **Traffic in** | Elastic IP → Caddy on the instance | Application Load Balancer + ACM; CloudFront | With one instance an ALB adds cost on new accounts and needs a real domain for ACM. Caddy gives automatic HTTPS for $0. The ALB is the first thing I'd add for real customers (below). |
| **Packaging** | Docker + Compose | systemd + virtualenv | The same image runs in CI, locally and in prod, and rollback is just "run the previous tag". |
| **Deploy** | GitHub Actions → ECR → SSM Run Command | SSH from CI with a stored key; CodeDeploy | No inbound port 22, no long-lived secrets, and the output is audited in SSM. CodeDeploy would also work but needs more moving parts for a single host. |
| **Secrets** | SSM Parameter Store (SecureString) | Secrets Manager | Parameter Store standard tier is free; Secrets Manager costs $0.40/secret/month. I'd switch for automatic rotation. |
| **IaC** | Terraform | CloudFormation; clicking in the console | Everything is reviewable, repeatable and removable with `terraform destroy`. |

### Nice-to-haves I picked, and why

- **Terraform (IaC)**: the whole environment is about 40 resources. Writing it down means I can rebuild it from scratch, reviewers can see every security group rule, and teardown is guaranteed (no forgotten resources = no surprise bill).
- **CI/CD with GitHub Actions**: deploying should be boring and identical every time. Every push is tested, and a broken build can never reach the server because the deploy waits for the health check and rolls back.
- *Small extras because they were nearly free:* **HTTPS** (Caddy + sslip.io) and **basic monitoring** (CloudWatch alarms + SNS email, an AWS Budget, container logs in CloudWatch, and an outside-in uptime check of `/health` from GitHub every 30 minutes).

---

## Security

- **No secrets in the repo.** The DB password is generated by Terraform, stored as an SSM SecureString, and written on the server to a root-only (`600`) env file at deploy time. `*.tfstate`, `*.tfvars` and env files are git-ignored.
- **Only the ports the app needs.** Internet → EC2: 80 and 443. EC2 → RDS: 5432, from the web security group only. **No SSH** (no key pair, no port 22); shell access goes through SSM Session Manager, which is IAM-authenticated and logged.
- **Database is private.** It sits in subnets with no internet route, `publicly_accessible = false`, storage is encrypted, and connections use TLS (`sslmode=require`; RDS enforces `rds.force_ssl`).
- **Least-privilege IAM.** The instance role can read only `/todo/*` parameters, pull only this ECR repo and write only to its log group. The GitHub role can push only to this repo and run commands only on this instance, and only from `main`.
- **Hardened instance.** IMDSv2 required (hop limit 1, so containers can't reach instance credentials) and an encrypted EBS root volume.
- **App level.** Parameterised SQL, auto-escaped templates (covered by a test), input length limits, a non-root container, security headers from Caddy, and health output that never leaks connection strings.

## Cost: staying inside the Free Tier

| Resource | Free Tier coverage | Notes |
|---|---|---|
| EC2 `t3.micro` | 750 h/month | One instance running 24/7 is about 730 h. CPU credits `standard`, so no burst charges |
| EBS 16 GB gp3 | 30 GB | |
| RDS `db.t3.micro`, 20 GB gp2, single-AZ | 750 h + 20 GB | Backup retention 1 day; storage autoscaling off |
| Public IPv4 (Elastic IP) | 750 h/month on legacy Free Tier; covered by credits on new accounts | About $3.60/month at list price, the one item to watch |
| ECR | 500 MB | Lifecycle policy keeps only the last 5 images |
| SSM Parameter Store (standard), Run Command, Session Manager | Free | |
| CloudWatch | 10 alarms, 5 GB logs | 5 alarms; logs kept 7 days |
| SNS email, AWS Budgets | Free (first 2 budgets) | |
| **Deliberately avoided** | | NAT Gateway (about $32/month), ALB, Multi-AZ RDS, Secrets Manager, Performance Insights, interface VPC endpoints |

Guardrails: an **AWS Budget** ($5/month) emails at 20% of actual spend and at 100% forecast. Credits are *excluded*, so it reflects real usage even when sign-up credits would hide it. `terraform destroy` removes everything, including the ECR images and the database (no final snapshot).

---

## Run it locally

Requires Docker.

```bash
docker compose -f docker-compose.dev.yml up --build
# open http://localhost:8000 and http://localhost:8000/health
```

Tests (need a Postgres; the dev compose one works):

```bash
pip install -r app/requirements-dev.txt
TEST_DATABASE_URL=postgresql://todo:localdev@localhost:5432/todo pytest -v app/tests
```

## Deploy it to AWS

**Prerequisites:** an AWS account, the AWS CLI logged in locally with an admin profile (`aws configure` / `aws sso login`; credentials stay on your machine), Terraform ≥ 1.6, and this repo pushed to GitHub as a **public** repo (the server clones it on first boot).

```bash
# 1. Provision (about 10 minutes, mostly RDS)
cd infra
cp terraform.tfvars.example terraform.tfvars   # set github_repo and alert_email
terraform init
terraform apply
```

2. **Confirm the SNS subscription** email AWS sends you, so alarms reach you.
3. In GitHub → *Settings → Secrets and variables → Actions → **Variables***, add the five values from `terraform output github_variables`: `AWS_REGION`, `AWS_ROLE_ARN`, `ECR_REPOSITORY_URL`, `INSTANCE_ID`, `APP_URL`. These are identifiers, not secrets.
4. Deploy: push to `main`, or *Actions → CI/CD → Run workflow*.
5. Open `terraform output app_url`. The first HTTPS request can take a few seconds while Caddy obtains the certificate.

Useful commands:

```bash
terraform output shell_command        # shell on the box via SSM, no SSH
aws logs tail /todo/app --follow      # app + caddy logs
```

**Teardown:** `cd infra && terraform destroy`.

## Repo layout

```
app/                 Flask app, templates, tests
Dockerfile           non-root image with a /health HEALTHCHECK
docker-compose.yml   prod stack on EC2: app + Caddy, logs to CloudWatch
docker-compose.dev.yml  local stack: app + throwaway Postgres
deploy/deploy.sh     runs on the instance via SSM: config → pull → up --wait → rollback
deploy/Caddyfile     HTTPS reverse proxy + security headers
infra/               Terraform: VPC, SGs, EC2, RDS, IAM/OIDC, ECR, SSM, alarms, budget
.github/workflows/   ci-cd.yml (test/build/deploy/smoke test), uptime.yml
docs/                architecture diagrams (Mermaid sources + PNG)
```

## What went wrong while building, and how I found the cause

> *Fill in with what actually happened when you deployed. See `docs/demo-script.md` for how to tell it. Structure: symptom → what I checked → real cause → fix → what I'd do to catch it earlier.*

## What I'd change before real customers used it

1. **No single points of failure:** an ALB in front of an Auto Scaling group across two AZs, and RDS Multi-AZ. Today one instance or one AZ going down takes the app down.
2. **A real domain** in Route 53 with an ACM certificate on the ALB, instead of sslip.io + Let's Encrypt on the box.
3. **Data safety:** longer backup retention and point-in-time recovery drills, deletion protection, a final snapshot on destroy, and schema migrations with a proper tool (Alembic) instead of `CREATE TABLE IF NOT EXISTS`.
4. **Secrets:** Secrets Manager with automatic rotation, or IAM database authentication.
5. **State and environments:** Terraform state in S3 with locking, plus a staging environment that deploys first, with promotion to prod behind an approval.
6. **Network:** move the instances to private subnets behind the ALB, add VPC endpoints for ECR/SSM/CloudWatch, and tighten egress. Add AWS WAF on the ALB.
7. **Observability:** structured JSON logs, request/latency/error-rate metrics with alarms (not just host health), tracing, and an on-call path for alerts.
8. **App:** authentication and per-user data, CSRF protection and rate limiting.
