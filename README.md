# BrightPath To-Do: a small app, deployed properly on AWS

A to-do list (Flask + PostgreSQL) running on a Linux EC2 instance, with the database on Amazon RDS. The app is intentionally tiny; the point of the repo is **how it is deployed and run**: infrastructure as code, pull-based CI/CD with no AWS keys outside AWS, HTTPS, least-privilege networking, monitoring and a hard look at cost.

| | |
|---|---|
| **Live app** | https://3-131-76-41.sslip.io |
| **Health check** | https://3-131-76-41.sslip.io/health |
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

On every push to `main`:

1. **GitHub Actions** runs the tests against a real Postgres service container (job `test`) and builds the Docker image.
2. On the server, a **systemd timer** runs [`deploy/poll.sh`](deploy/poll.sh) every minute. It `git fetch`es `main`, and when there is a new commit **whose `test` check passed**, it checks it out and runs [`deploy/deploy.sh`](deploy/deploy.sh).
3. `deploy.sh` reads config and the DB password from **SSM Parameter Store**, builds the image for that commit, and runs `docker compose up --wait`, which waits for the container's `/health` check. If the new version never becomes healthy, it **rolls back** to the previous image and marks the commit as bad so it isn't retried.
4. Back in GitHub Actions, the `verify-deploy` job polls the public `/health` until it reports the *new* commit, so the pipeline goes red if the deploy didn't land.

**Finding out when something breaks:** CloudWatch alarms (EC2 status checks with automatic recovery, CPU credits, RDS CPU and free storage) and the AWS Budget email through SNS; container logs go to CloudWatch Logs (`/todo/app`); and a GitHub Actions uptime check hits `/health` from outside every 30 minutes.

No AWS credentials exist outside AWS: the instance uses its IAM role, and GitHub has nothing it could leak. (This design came out of a real problem; see [What went wrong](#what-went-wrong-while-building-and-how-i-found-the-cause).)

Diagram sources: [`docs/architecture.drawio`](docs/architecture.drawio) (draw.io; open at [app.diagrams.net](https://app.diagrams.net)) and [`docs/deploy-flow.mmd`](docs/deploy-flow.mmd) (Mermaid).

---

## Main choices and alternatives considered

| Decision | Chose | Considered | Why |
|---|---|---|---|
| **Compute** | EC2 `t3.micro` | `t4g.micro` (Graviton/ARM), `t2.micro` | `t3.micro` is Free Tier-eligible for **both** older accounts and accounts created after 15 July 2025. `t4g` is cheaper per hour but would need ARM/multi-arch image builds; `t2` is older and not eligible on new accounts. CPU credits are set to `standard`, so a busy CPU is throttled rather than billed. |
| **Linux distro** | Amazon Linux 2023 | Ubuntu 24.04 | AL2023 ships with the SSM agent and AWS CLI, is tuned for EC2 and is supported by AWS. Ubuntu would work just as well; AL2023 meant less bootstrap code. |
| **Database** | RDS PostgreSQL 16 `db.t3.micro` | Postgres in a container on the same EC2; DynamoDB | Managed backups, patching, encryption and a private endpoint. Running Postgres on the same 1 GB box would tie the data to the server's lifecycle and compete for RAM. DynamoDB is always-free, but relational SQL is closer to a typical SaaS backend and easier to reason about. |
| **Traffic in** | Elastic IP → Caddy on the instance | Application Load Balancer + ACM; CloudFront | With one instance an ALB adds cost on new accounts and needs a real domain for ACM. Caddy gives automatic HTTPS for $0. The ALB is the first thing I'd add for real customers (below). |
| **Packaging** | Docker + Compose | systemd + virtualenv | The same Dockerfile runs in CI, locally and in prod, and rollback is just "run the previous image". |
| **Deploy** | Pull-based: GitHub Actions tests, the server pulls and deploys | Push from Actions via OIDC → ECR → SSM (my first design, blocked by the account's SCP); IAM user access keys in GitHub; SSH from CI | No inbound port 22 and no AWS credentials in GitHub. Long-lived access keys would have worked around the SCP, but they're exactly the kind of secret the brief says not to spread around. Trade-off: up to ~1 minute of deploy latency, and the server builds the image itself (fine for a small app). |
| **Secrets** | SSM Parameter Store (SecureString) | Secrets Manager | Parameter Store standard tier is free; Secrets Manager costs $0.40/secret/month. I'd switch for automatic rotation. |
| **IaC** | Terraform | CloudFormation; clicking in the console | Everything is reviewable, repeatable and removable with `terraform destroy`. |

### Nice-to-haves I picked, and why

- **Terraform (IaC)**: the whole environment is about 40 resources. Writing it down means I can rebuild it from scratch, reviewers can see every security group rule, and teardown is guaranteed (no forgotten resources = no surprise bill).
- **CI/CD (GitHub Actions + pull-based deploy)**: deploying should be boring and identical every time. Every push is tested; the server only deploys commits whose tests passed; a broken release can't stay live because the deploy waits for the health check and rolls back; and the pipeline itself confirms the new version is live.
- *Small extras because they were nearly free:* **HTTPS** (Caddy + sslip.io) and **basic monitoring** (CloudWatch alarms + SNS email, an AWS Budget, container logs in CloudWatch, and an outside-in uptime check of `/health` from GitHub every 30 minutes).

---

## Security

- **No secrets in the repo.** The DB password is generated by Terraform, stored as an SSM SecureString, and written on the server to a root-only (`600`) env file at deploy time. `*.tfstate`, `*.tfvars` and env files are git-ignored.
- **Only the ports the app needs.** Internet → EC2: 80 and 443. EC2 → RDS: 5432, from the web security group only. **No SSH** (no key pair, no port 22); shell access goes through SSM Session Manager, which is IAM-authenticated and logged.
- **Database is private.** It sits in subnets with no internet route, `publicly_accessible = false`, storage is encrypted, and connections use TLS (`sslmode=require`; RDS enforces `rds.force_ssl`).
- **Least-privilege IAM.** The instance role can read only `/todo/*` parameters (plus SSM agent basics) and write only to its own log group. GitHub has no AWS access at all.
- **Hardened instance.** IMDSv2 required (hop limit 1, so containers can't reach instance credentials) and an encrypted EBS root volume.
- **App level.** Parameterised SQL, auto-escaped templates (covered by a test), input length limits, a non-root container, security headers from Caddy, and health output that never leaks connection strings.

## Cost: staying inside the Free Tier

| Resource | Free Tier coverage | Notes |
|---|---|---|
| EC2 `t3.micro` | 750 h/month | One instance running 24/7 is about 730 h. CPU credits `standard`, so no burst charges |
| EBS 16 GB gp3 | 30 GB | |
| RDS `db.t3.micro`, 20 GB gp2, single-AZ | 750 h + 20 GB | Backup retention 1 day; storage autoscaling off |
| Public IPv4 (Elastic IP) | 750 h/month on legacy Free Tier; covered by credits on new accounts | About $3.60/month at list price, the one item to watch |
| SSM Parameter Store (standard), Run Command, Session Manager | Free | |
| CloudWatch | 10 alarms, 5 GB logs | 5 alarms; logs kept 7 days |
| SNS email, AWS Budgets | Free (first 2 budgets) | |
| **Deliberately avoided** | | NAT Gateway (about $32/month), ALB, Multi-AZ RDS, Secrets Manager, Performance Insights, interface VPC endpoints |

Guardrails: an **AWS Budget** ($5/month) emails at 20% of actual spend and at 100% forecast. Credits are *excluded*, so it reflects real usage even when sign-up credits would hide it. `terraform destroy` removes everything, including the database (no final snapshot).

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

**Prerequisites:** an AWS account and this repo on GitHub as a **public** repo (the server clones it). No local AWS keys are needed: provisioning runs in **AWS CloudShell**, which uses your console login.

1. Open CloudShell in the console (I used `us-east-2`; new Free plan accounts are limited to one region) and run:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/infra/cloudshell-apply.sh) <owner>/<repo> <alert-email>
   ```
   It installs Terraform, clones the repo, writes `terraform.tfvars` and runs `terraform apply` (about 10 minutes, mostly RDS). State stays in your CloudShell home directory.
2. **Confirm the SNS subscription** email AWS sends you, so alarms reach you.
3. In GitHub → *Settings → Secrets and variables → Actions → Variables*, add `APP_URL` = `terraform output app_url` (used by `verify-deploy` and the uptime check).
4. That's it. On first boot the instance installs the deploy timer and deploys the latest passing commit. After that, every push to `main` goes live within about a minute of its tests passing.

Prefer running Terraform locally? `cd infra && cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply` with any admin AWS profile.

Useful commands (CloudShell):

```bash
aws ssm start-session --target <instance-id>              # shell on the box, no SSH
aws logs tail /todo/app --follow                          # app + caddy logs
# on the box: journalctl -u todo-autodeploy -f            # deploy log
```

**Self-destruct (cost safety net):** set `auto_delete_at` (e.g. `AUTO_DELETE_AT=2027-01-06T13:00:00` before running `cloudshell-apply.sh`). Terraform then creates one-time **EventBridge Scheduler** jobs that terminate the EC2 instance, delete the RDS database (no snapshot) and, an hour later, release the Elastic IP. Those are the only resources that cost money; whatever is left is free and goes away with `terraform destroy`. This demo is set to delete itself on **6 January 2027**.

**Teardown:** `cd ~/<repo>/infra && TF_DATA_DIR=/tmp/tfdata terraform init && TF_DATA_DIR=/tmp/tfdata terraform destroy`.

## Repo layout

```
app/                 Flask app, templates, tests
Dockerfile           non-root image with a /health HEALTHCHECK
docker-compose.yml   prod stack on EC2: app + Caddy, logs to CloudWatch
docker-compose.dev.yml  local stack: app + throwaway Postgres
deploy/poll.sh       on the instance, every minute: new commit on main + CI passed? → deploy
deploy/deploy.sh     config from SSM → docker build → up --wait → rollback if unhealthy
deploy/systemd/      the timer + service that run poll.sh
deploy/Caddyfile     HTTPS reverse proxy + security headers
infra/               Terraform: VPC, SGs, EC2, RDS, IAM, SSM, alarms, budget (+ cloudshell-apply.sh)
.github/workflows/   ci-cd.yml (test → build → verify-deploy), uptime.yml
docs/                architecture diagrams (Mermaid sources + PNG)
```

## What went wrong while building, and how I found the cause

**Symptom.** My first `terraform apply` created about 40 resources, then failed on one:

```
Error: creating IAM OIDC Provider: ... AccessDenied: ... is not authorized to perform:
iam:CreateOpenIDConnectProvider ... with an explicit deny in a service control policy
```

**What I checked.** I was signed in with full admin access, so this wasn't a missing IAM permission on my role. The key words were *"explicit deny in a service control policy"*. An SCP sits above IAM at the AWS Organizations level, and an explicit deny there beats any Allow. A brand-new account shouldn't have one, so I looked at how the account was set up: new accounts on AWS's **Free plan** (created after July 2025) run inside an AWS-managed organization. It restricts some actions and also limits you to one region, which is why CloudShell refused `us-west-2` earlier and I moved to `us-east-2`.

**Real cause.** The Free plan's SCP blocks creating an IAM OIDC identity provider, which is exactly what GitHub Actions needs to get short-lived AWS credentials. So my push-based pipeline (Actions → ECR → SSM Run Command) could never authenticate to AWS in this account, however I wrote the IAM policies.

**Fix.** I had three options: upgrade the account to the paid plan, create an IAM user and put long-lived access keys in GitHub, or **flip the direction of deployment**. I chose the third. The instance already has an IAM role, so it pulls from GitHub, only deploys commits whose tests passed, and keeps the health-check rollback. GitHub never holds AWS credentials, which is a better security posture than the keys workaround. I removed ECR and the GitHub role from Terraform, and the second `apply` converged cleanly.

**What I'd do to catch it earlier.** Check the account's guardrails first (`aws organizations describe-organization`, the Free plan's supported-services list) before designing around a feature, and apply the identity and access pieces (`-target`) before the slow resources like RDS, so a blocker shows up in seconds instead of after an 8-minute database build.

## What I'd change before real customers used it

1. **No single points of failure:** an ALB in front of an Auto Scaling group across two AZs, and RDS Multi-AZ. Today one instance or one AZ going down takes the app down.
2. **A real domain** in Route 53 with an ACM certificate on the ALB, instead of sslip.io + Let's Encrypt on the box.
3. **Data safety:** longer backup retention and point-in-time recovery drills, deletion protection, a final snapshot on destroy, and schema migrations with a proper tool (Alembic) instead of `CREATE TABLE IF NOT EXISTS`.
4. **Secrets:** Secrets Manager with automatic rotation, or IAM database authentication.
5. **State and environments:** Terraform state in S3 with locking, plus a staging environment that deploys first, with promotion to prod behind an approval.
6. **Network:** move the instances to private subnets behind the ALB, add VPC endpoints for ECR/SSM/CloudWatch, and tighten egress. Add AWS WAF on the ALB.
7. **Observability:** structured JSON logs, request/latency/error-rate metrics with alarms (not just host health), tracing, and an on-call path for alerts.
8. **App:** authentication and per-user data, CSRF protection and rate limiting.
