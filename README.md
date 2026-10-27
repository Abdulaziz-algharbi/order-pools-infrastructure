# OrderPools Infrastructure

Bash + AWS CLI infrastructure and deployment automation for OrderPools. Deliberately **not** Terraform/CloudFormation/CDK/Pulumi — every resource is created with an explicit, commented `aws` CLI call, on purpose, as a learning exercise in AWS fundamentals. If you're new to this repo, read a script before running it; the comments explain *why* each resource exists, not just what the command does.

Sibling repos: `order-pools-app` (Vite/React frontend) and `order-pools-backend` (Express/TypeScript backend) are expected checked out next to this repo:

```text
orderPool/
├── infrastructure/     (this repo)
├── order-pools-app/
└── order-pools-backend/
```

## 1. Architecture

```text
                         Route 53
                            |
              +-------------+-------------+
              |                           |
       app.<domain>                  api.<domain>
              |                           |
              v                           v
         CloudFront                      ALB
              |                           |
              v                           v
        Private S3 bucket             EC2 (public subnet,
        Vite/React SPA                SG-locked, no SSH)
                                          |
                                          v
                                  MongoDB Atlas
```

Two deliberate departures from the "obvious" version of this diagram, both explained in depth in [Security considerations](#18-security-considerations):

- **No NAT Gateway.** The backend EC2 instance sits in a *public* subnet with a direct route to the Internet Gateway, not a private subnet behind a NAT Gateway. The security group is the enforcement boundary instead (ALB-only inbound; outbound limited to 443/80/27017/587/tcp + DNS — see [Security considerations](#18-security-considerations) for exactly why each port is there) — this was a deliberate cost/complexity trade-off for a dev/demo-stage project (a NAT Gateway alone runs ~$40+/month).
- **In-place restart deploys**, not blue/green or canary. There's a single EC2 instance; deploying restarts the same process in place. A few seconds of downtime per deploy, and a failed deploy takes down the only target until rolled back. Deliberate, confirmed trade-off for this stage — see [Backend deployment](#8-backend-deployment).

**Resource dependency order** (what `deploy.sh` actually runs, in order):

```text
VPC -> Internet Gateway -> public subnets (2 AZs) -> route table
  -> security groups (ALB-SG, backend-SG)
  -> IAM (EC2 instance role + profile)
  -> EC2 instance
  -> ECR image repository, CloudWatch log group
  -> ACM cert (api.<domain>, regional)
  -> target group -> ALB (HTTPS:443 + HTTP:80 redirect)
  -> Route 53 record for api.<domain>

  -> frontend S3 bucket
  -> ACM cert (app.<domain>, MUST be us-east-1)
  -> CloudFront distribution (Origin Access Control)
  -> bucket policy (scoped to that one distribution)
  -> Route 53 record for app.<domain>
```

Frontend and backend infrastructure are independent of each other (either half can be created/destroyed without the other); DNS/TLS steps for each depend only on their own half being ready.

## 2. Prerequisites

- `bash`, `aws` (CLI v2), `jq`, `git` — every script checks for these and fails immediately with a clear message if one is missing.
- `docker` (with buildx, as in Docker Desktop) and `node`/`npm` — not needed to provision infrastructure, but required to deploy the applications from a laptop: `backend/deploy-backend.sh` builds the backend's Docker image, `frontend/deploy-frontend.sh` builds the frontend with npm.
- `gh` (GitHub CLI), logged in with the `workflow` scope (`gh auth login`) — only for `deploy-apps.sh`, which asks each app repo's GitHub Actions workflow to deploy (see [Dev deployment](#5-dev-deployment)).
- An AWS account with `aws configure` (or `AWS_PROFILE`) already working — verify with `aws sts get-caller-identity`.
- That identity (an IAM user you manage yourself; these scripts never change its permissions) needs full access to EC2 (which covers the load balancer), VPC, IAM, S3, CloudFront, Route 53, ACM, SSM, SES, **ECR** and **CloudWatch Logs**, plus `tag:GetResources` (for `destroy.sh`'s leftover check). When a service is added here, add its permission to that user too. To check actions before a run fails on one:
  `aws iam simulate-principal-policy --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" --action-names ecr:CreateRepository logs:CreateLogGroup --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text`
- A Route 53 hosted zone already created for your domain (NS/SOA records set at your registrar) — this project uses subdomains within an existing zone, it doesn't create the zone itself.
- A MongoDB Atlas cluster — see [MongoDB Atlas](#14-mongodb-atlas). Not provisioned by this repo.

## 3. AWS account setup

The very first script you run for a given environment prints the caller's AWS account ID and **pins it** into `config/<env>.local.env` (gitignored). Every script run after that compares the live account against the pinned one and refuses to continue on a mismatch — this is the main defense against accidentally running `./destroy.sh prod` against the wrong AWS account because a different `AWS_PROFILE` happened to be exported. If you deliberately need to re-point an environment at a different account, delete that `.local.env` file.

## 4. Configuration

| File | Committed? | Purpose |
|---|---|---|
| `config/common.env` | Yes | Values shared by every environment (project name, tag keys) |
| `config/<env>.env` | Yes | Per-environment config: region, VPC/subnet CIDRs, instance type, root volume size, domain names |
| `config/<env>.local.env` | **No** (gitignored) | Auto-generated account pin — see above |
| `config/<env>.secrets.env` | **No** (gitignored) | Real application secrets (Atlas URI, JWT secrets, ...) — copy from the `.example` template and fill in |
| `environments/<env>/outputs.env` | **No** (gitignored) | Local cache of resource IDs, for fast re-runs on your own machine |

These are plain bash files, `source`d by every script — not dotenv files parsed by a library, which is why `config/<env>.env` can contain a bash array (`PUBLIC_SUBNET_CIDRS=(...)`).

Resource IDs have a second, canonical home: **SSM Parameter Store**, under `/order-pool/<env>/state/...` (written by `lib/state.sh`). This is what lets a GitHub Actions runner (Phase 6, which has never seen your local `outputs.env`) resolve the same instance ID, bucket name, etc. that your laptop created. Application secrets live in a *separate* namespace, `/order-pool/<env>/backend/...` — see [Secrets](#10-secrets) for why these two must never overlap.

## 5. Dev deployment

```bash
cd infrastructure
./deploy.sh dev                              # provisions all AWS infrastructure
cp config/dev.secrets.env.example config/dev.secrets.env
$EDITOR config/dev.secrets.env               # fill in the real Atlas password, JWT secrets, etc.
./email/01-ses.sh dev                        # SES domain + DNS + SMTP credentials -> secrets file (see §19)
./deploy-apps.sh dev                         # config -> SSM, then both apps' CI deploys main
./status.sh dev                              # live health check of everything above
./test/verify-dev.sh dev                     # pass/fail assertions — see below
```

`deploy.sh` never builds or ships application code itself (see [GitHub Actions](#9-github-actions) for why that split matters). Its last step, when `config/<env>.secrets.env` already exists (as it does after a destroy, which leaves it on disk), is `deploy-apps.sh`; on a first build it stops and prints the steps above instead. `deploy-apps.sh <env>`:

1. shows the backend instance's current public IP and waits for you to confirm it's on MongoDB Atlas's Network Access list — every rebuild gets a new IP, and Atlas isn't managed by this repo (see [MongoDB Atlas](#14-mongodb-atlas)), so this stays a manual step;
2. pushes `config/<env>.secrets.env` to SSM with `backend/env-to-ssm.sh` — `destroy.sh` deleted it from there, and the backend can't start without it;
3. runs `gh workflow run deploy.yml` on `main` in `order-pools-backend` and `order-pools-app`, so both are tested, built and deployed by CI exactly as a push would. While the environment was down, every push to either repo was tested but its deploy skipped, so this is what brings a rebuilt environment up to date.

It only queues the two runs; follow them with `gh run list --repo <owner>/<repo> --workflow deploy.yml`. To deploy from the laptop instead of CI (needs `docker` and `node`/`npm`): `./backend/env-to-ssm.sh dev`, `./backend/deploy-backend.sh dev`, `./frontend/deploy-frontend.sh dev`.

`test/verify-dev.sh` is read-only, like `status.sh`, but asserts explicit pass/fail per resource (existence, key config values, live HTTP checks) instead of just printing state — the closest thing this plain-bash toolkit has to a test suite, and a substitute for re-clicking through every AWS console page by hand after a change. Exits non-zero and lists every failure if anything's wrong.

If you also want GitHub Actions able to deploy this environment, run `./iam/02-github-oidc-roles.sh dev` once as well (not part of `deploy.sh`'s sequence — setting up CI trust roles is a deliberate, separate action, not something that should happen silently every time you provision infrastructure) and set the resulting role ARNs as GitHub environment variables per [GitHub Actions](#9-github-actions).

## 6. Prod deployment

Not yet configured. `config/prod.env.example` is a placeholder — copy it to `config/prod.env`, fill in production values (region, CIDRs, and note the domain convention: `dev` uses `dev-api.<domain>`/`dev-app.<domain>`, reserving the bare `api.<domain>`/`app.<domain>` for `prod`), then run the exact same command sequence with `prod` in place of `dev`. Before treating a `prod` environment built this way as genuinely production-grade, revisit the trade-offs in [Security considerations](#18-security-considerations) — several were explicitly accepted for a dev/demo stage and may not be the right call once real traffic/users are involved (single EC2 instance with no ASG, in-place restart deploys, single NAT-less AZ egress path).

## 7. Frontend deployment

`frontend/01-s3-bucket.sh` creates a fully private bucket (no static-website-hosting mode, no public bucket policy) — `frontend/02-cloudfront.sh` creates an Origin Access Control (OAC) and a CloudFront distribution that reads from it, and `frontend/03-bucket-policy.sh` grants read access to *only that specific distribution's* service principal (via an `AWS:SourceArn` condition), never to CloudFront in general.

`frontend/deploy-frontend.sh`:
1. Builds `order-pools-app` with `VITE_API_BASE_URL` **exported as a shell env var** (`https://<api-domain>/api/v1`) rather than baked into the committed `.env.production` — Vite's documented precedence rule is that an already-set process env var overrides a `.env` file value, so `dev` and `prod` builds can target different API domains without editing a tracked file.
2. Syncs the build to S3 in two passes: everything except `index.html` gets `Cache-Control: public,max-age=31536000,immutable` (safe, because Vite's hashed filenames change on every code change); `index.html` itself gets `no-cache` (it must always be revalidated, since it's what references those hashed filenames — caching it would let a browser serve a stale `index.html` pointing at JS/CSS chunks the same deploy's `--delete` just removed).
3. Invalidates `/*` on the distribution. This is effectively free — CloudFront bills per invalidation *path string*, not per object, so a full-site invalidation counts as 1 against the 1,000/month free tier.

CloudFront's `CustomErrorResponses` rewrite both 403 and 404 to `/index.html` with a 200 — required for React Router: a deep link like `/retailer/pools` isn't a real S3 object, so without this rewrite a refresh or shared link would show a raw error page instead of letting the client-side router take over.

## 8. Backend deployment

The backend ships as a **Docker image** built from `order-pools-backend/Dockerfile`. It is built once, tested, pushed to a private ECR repository (`backend/05-ecr-repository.sh`) tagged with its git commit SHA, and pulled by the instance. Nothing is compiled or installed on the instance at deploy time, so what runs there is byte-for-byte what was tested. It replaced an earlier flow that uploaded a tarball of `dist/` to an S3 bucket for the instance to download, then ran `npm ci` there under a systemd unit; that bucket and its permissions are gone, and the backend uses no S3 at all.

`backend/01-ec2-instance.sh` launches a single Ubuntu 24.04 LTS instance (AMI resolved dynamically via Canonical's own SSM public parameter — never hardcoded) with an encrypted gp3 root volume of `ROOT_VOLUME_GB` and Docker Engine + the Compose plugin installed (`backend/bootstrap.sh.tmpl`). There's no Node.js on it: the Node version is the image's.

`backend/deploy-backend.sh <env>` does from a laptop what GitHub Actions does on every push (section 9):
1. Builds the image from your `order-pools-backend` checkout for `IMAGE_PLATFORM` (the instance's CPU — `linux/amd64` for t3, built under emulation on an Apple Silicon Mac). It's tagged with the commit SHA, or `<sha>-dirty-<time>` if the checkout has uncommitted changes. If that tag is already in ECR (e.g. CI built it), it deploys that image instead of building.
2. Pushes it to ECR (tags are immutable: a tag always means one exact build).
3. Sends `deploy-remote.sh.tmpl` to the instance via SSM (`lib/ssm.sh`, which polls for up to 10 minutes). On the instance, that script:
   - logs in to ECR with the instance role and pulls the image;
   - writes `/opt/order-pool-backend/shared/.env` from SSM Parameter Store;
   - seeds the admins in a throwaway container of the new image;
   - writes `/opt/order-pool-backend/compose.yml` and runs `docker compose up -d`, which replaces the running container;
   - checks `/ping` locally for up to ~90s and records the tag in `/opt/order-pool-backend/deployed-tags`;
   - prunes old images, keeping the 3 most recently deployed.
4. Polls the ALB target group until it reports healthy.

On the instance, Docker (not systemd) keeps the backend running: the container has `restart: unless-stopped`, and the Docker service starts on boot. The container's stdout goes to CloudWatch Logs (`backend/06-log-group.sh`, retention `LOG_RETENTION_DAYS`, 7 days in dev), one stream per deploy: `aws logs tail /order-pool/<env>/backend --follow`. On stop, Docker sends `SIGTERM`, which `order-pools-backend/src/server.ts` handles to close the HTTP server and the Mongo connection cleanly.

This is **pull-based**: the instance pulls the image and reads its parameters over its own IAM role; nothing is ever pushed to it over SSH (there is no SSH — administration is SSM Session Manager only).

**Deploy strategy is in-place restart**, not blue/green or canary — confirmed deliberately for this project's dev/demo stage (see the architecture note above): the old container stops, then the new one starts, a few seconds apart. A failed health check leaves the backend down until a rollback.

`backend/rollback-backend.sh <env> [tag]` is a deploy of an earlier image: the same remote script, with `previous` instead of a new tag (or a specific tag from ECR).
- If the latest deploy failed, `previous` means the last image that was healthy on the instance.
- Otherwise it means the image deployed before the current one, so rolling back twice toggles between the two most recent images.
- It re-reads the settings from SSM, so the image goes back but the configuration stays current.

## 9. GitHub Actions

Implemented (Phase 6). `iam/02-github-oidc-roles.sh <env>` creates one OIDC identity provider (account-wide, once) and three separate IAM roles, each trusted only by its own repo + this specific environment (via the token's `repository`/`environment` claims, not long-lived AWS access keys):

```text
order-pool-<env>-infra-deploy      -> broad (could create/destroy the whole stack); provisioned but
                                       DELIBERATELY not used by any workflow — see below
order-pool-<env>-frontend-deploy   -> scoped to the frontend S3 bucket + CreateInvalidation; trusted by order-pools-app
order-pool-<env>-backend-deploy    -> scoped to the backend's ECR repository (push) + ssm:SendCommand on Project/Environment-tagged
                                       instances + read of /order-pool/<env>/state/backend/* and .../backend/*;
                                       trusted by order-pools-backend
```

**Infrastructure provisioning stays manual, on purpose — no `infra.yml` workflow exists.** `deploy.sh`/`destroy.sh` are run by a human, from a terminal, with that person's own AWS credentials and judgment in the loop. This was a deliberate call, not an oversight: application CI/CD (below) solves a real, recurring problem — app code changes often, and each deploy is a fast, low-risk, repeatable operation that should just happen on push. Infra doesn't have that shape. VPC/IAM/security-group/ALB changes are infrequent and high-blast-radius, not a "ship many times a day" workflow, and `infra-deploy` is by far the most privileged of the three roles — handing that much power to a CI pipeline triggerable by anything with push access is a materially bigger security surface than a human running it themselves, with the ability to Ctrl-C mid-`destroy.sh`. There's also no multi-person coordination problem here to justify it (solo project) — that's the actual scenario where infra-via-CI would earn its complexity. `iam/02-github-oidc-roles.sh` still provisions the `infra-deploy` role (harmless, unused, and cheap to keep around if a future team-scale need for it ever materializes), it's just never assumed by anything today.

**Workflows**, one per app repo (deliberately none in `order-pools-infrastructure` itself):

- `order-pools-backend/.github/workflows/deploy.yml` — runs the unit tests, builds the Docker image, runs the whole API suite against that image (with a MongoDB replica set started from the repo's `docker-compose.yml`), pushes it to ECR as `:<commit SHA>`, then calls a **reusable workflow** defined in `order-pools-infrastructure/.github/workflows/deploy-backend.yml` with that tag to do the actual render/SSM-send/poll mechanics.
- `order-pools-app/.github/workflows/deploy.yml` — fully self-contained: a `test` job (lint, Vitest, build), then a `deploy` job: build (with `VITE_API_BASE_URL` injected the same way `deploy-frontend.sh` does), `s3 sync` (two-pass cache headers), CloudFront invalidation, no cross-repo call.

**Only deploying while the environment is up.** Dev is destroyed whenever it isn't in use, so both workflows test every push regardless, then check SSM for the environment's state parameters (`/order-pool/<env>/state/backend/*`, `.../state/frontend/*` — `deploy.sh` writes them, `destroy.sh` deletes them) before pushing or deploying anything. All there: deploy. None there: skip the deploy with a warning ("tested but NOT deployed"), and the run still passes. Only some there: fail, since that's a half-built or half-destroyed environment (check `./status.sh`). Those parameters are the flag — there's no separate "is it up" variable to keep in sync with reality. The check works with the environment gone because `destroy.sh` keeps the GitHub OIDC roles. Once the environment is rebuilt, `deploy-apps.sh` (run by `deploy.sh`) deploys what was skipped — see [Dev deployment](#5-dev-deployment).

Both trigger on **push to `main`** (real continuous deployment) as well as manual `workflow_dispatch`, and both are confirmed working end-to-end against the live `dev` environment.

**Why the backend calls a reusable workflow but the frontend doesn't, even though both mirror a local script**: reusable workflows (`on: workflow_call`) are GitHub's sanctioned way to share workflow logic across repos without a PAT or deploy key — unlike a plain `actions/checkout` of a different repo, which the default `GITHUB_TOKEN` cannot do for a private repo regardless of ownership (confirmed live: this is *why* `order-pools-infrastructure` is public — a called reusable workflow's own `checkout` step needs to read its own repo's files, e.g. `deploy-remote.sh.tmpl`, and that specifically requires the repo to be public or a PAT to be introduced; made public since nothing secret lives in it). The backend's deploy mechanics (render a template, send an SSM command, poll its status, poll target-group health) are substantial enough that duplicating them into `order-pools-backend`'s own workflow would be a real drift risk. The frontend's remaining logic after "build" is a handful of straightforward `aws s3`/`aws cloudfront` calls — small enough that the added indirection of a cross-repo call would cost more clarity than the duplication it avoids, which would cut against this project's own explicit "don't hide AWS CLI commands behind unnecessary abstraction" learning goal. Build itself (`npm ci`/`npm run build`) is inherently repo-local either way and was never a candidate for centralizing — it can only ever run where the app's own source is checked out.

Also required for the reusable-workflow call specifically: `order-pools-infrastructure`'s repo-level Actions "access" setting must allow calls from other repos owned by the same account (Settings → Actions → General → Access — defaults to "Not accessible", confirmed live) — separate from, and in addition to, the repo being public.

Each repo needs these set as **environment variables** (not secrets — none of these are sensitive) under Settings → Environments → `<env>` → Variables, printed at the end of `iam/02-github-oidc-roles.sh`'s output, or set directly with `gh variable set NAME --env <env> --body VALUE --repo <owner>/<repo>`:

| Repo | Variables |
|---|---|
| `order-pools-app` | `FRONTEND_DEPLOY_ROLE_ARN`, `AWS_REGION`, `BACKEND_DOMAIN` |
| `order-pools-backend` | `BACKEND_DEPLOY_ROLE_ARN`, `AWS_REGION`, `BACKEND_PORT` |

A GitHub Actions runner resolves AWS resource IDs exactly the way your laptop does — `aws ssm get-parameter --name /order-pool/<env>/state/backend/instance-id`, etc. — which is the entire reason those IDs live in SSM Parameter Store as the canonical copy (`lib/state.sh`) rather than only in a local, gitignored cache file a runner could never see.

## 10. Secrets

**SSM Parameter Store, `SecureString` type, the default AWS-managed `alias/aws/ssm` KMS key** — not Secrets Manager. This project has a small, fixed set of long-lived secrets with no rotation requirement; Secrets Manager's main advantage (automatic rotation) doesn't apply here, and Parameter Store's standard tier is free where Secrets Manager charges per secret per month. If automatic Atlas-credential rotation ever becomes a requirement, migrating to Secrets Manager then is a clean incremental change, not a reason to pay for it now.

**Namespace convention** (see `lib/state.sh` and `backend/env-to-ssm.sh`):
- `/order-pool/<env>/state/...` — non-secret resource IDs (VPC, subnet, instance, ALB ARNs, ...), `String` type, written by every provisioning script.
- `/order-pool/<env>/backend/...` — actual application secrets/config (`PORT`, `PROD_MONGO_URI`, `JWT_TOKEN_SECRET`, ...), `SecureString` type, written only by `env-to-ssm.sh` from your local `config/<env>.secrets.env`.

These must stay separate: `deploy-remote.sh.tmpl` builds the app's `.env` file with `get-parameters-by-path` against the `backend/` branch specifically — if resource-ID state ever lived there too, every deploy would leak junk keys like `instance-id=i-0abc...` into the running app's environment. (This exact bug existed briefly during development and was caught and fixed before Phase 6.)

Never commit `config/<env>.secrets.env` — it's gitignored. Only `config/<env>.secrets.env.example` (blank template) is tracked.

## 11. DNS

A single pre-existing Route 53 hosted zone covers the whole domain; this project only adds records within it, never creates the zone. Two ALIAS records per environment (not CNAMEs — aliases can coexist with other records at the same name and work at a zone apex, which CNAMEs can't):

- `api.<domain>` (or `dev-api.<domain>`) → the ALB, via its `CanonicalHostedZoneId` (looked up per-region, not hardcoded).
- `app.<domain>` (or `dev-app.<domain>`) → the CloudFront distribution, via the fixed constant `Z2FDTNDATAQYW2` — every CloudFront distribution on every AWS account shares this same hosted zone ID; it's a documented AWS platform constant, not a per-resource value to look up.

## 12. TLS

Two separate ACM certificates, in two different regions — this is the single easiest mistake to make in this whole stack:

- **Backend cert**: same region as the ALB (`eu-north-1` in `config/dev.env`). Requested and DNS-validated by `dns-tls/01-acm-backend.sh`.
- **Frontend cert**: **must** be `us-east-1`, regardless of what region everything else runs in — a hard CloudFront requirement. `dns-tls/03-acm-frontend.sh` passes `--region us-east-1` explicitly on every `aws acm` call rather than relying on any ambient default, specifically because getting this wrong doesn't error — it silently produces a valid certificate that CloudFront simply can't see or use.

Both use DNS validation (not email): ACM hands back a CNAME record, the script publishes it to Route 53 itself, and ACM polls for it — no human ever clicks a validation email link, which is what makes this fully scriptable.

## 13. SSM

No SSH anywhere in this stack — the backend security group doesn't even have port 22 as a concept. All administration and deployment goes through AWS Systems Manager:
- **Session Manager** (`aws ssm start-session --target <instance-id>`) for an interactive shell, e.g. to read `/var/log/order-pool-bootstrap.log`.
- **Run Command** (`aws ssm send-command`, document `AWS-RunShellScript`) for `deploy-backend.sh`/`rollback-backend.sh` to execute a script on the instance.

Both work because the instance's IAM role (`iam/01-ec2-instance-role.sh`) has `AmazonSSMManagedInstanceCore` attached, and the SSM Agent (pre-installed on Canonical's Ubuntu AMIs) registers with the service automatically on boot — nothing to install by hand.

## 14. MongoDB Atlas

**Not provisioned by this repo** — Atlas is a separate SaaS, and its API requires its own credentials this project was never given, so these steps are manual:

1. Create a cluster (M0 free tier is fine for dev — it's still a replica set, so Mongoose transactions work exactly like the M10+ dedicated tier).
2. Database Access → create a DB user scoped to the `order-pool` database.
3. **Network Access**: allow-list the backend EC2 instance's public IP — get it from `./status.sh <env>` (row "EC2 public IP") or the output of `backend/01-ec2-instance.sh`. This is the instance's *own* public IP, not a NAT Gateway Elastic IP, because this project has no NAT Gateway (see [Security considerations](#18-security-considerations)). It stays stable for the life of a running instance, but **will change if the instance is ever terminated and relaunched** — re-check and update Atlas's allow-list if that happens. `deploy-apps.sh` (run by `deploy.sh`) prints the current IP and waits for you to confirm it's there before deploying the backend.
4. Grab the `mongodb+srv://` connection string and put it, with the real password, into `config/<env>.secrets.env`'s `PROD_MONGO_URI` — no `replicaSet=`/`directConnection=` query params needed (unlike local dev's single-node replica set), since an Atlas cluster's SRV record already encodes everything the driver needs.

## 15. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| A script dies with "account does not match the account pinned" | Wrong `AWS_PROFILE`/credentials active for this environment. Confirm with `aws sts get-caller-identity`, or delete `config/<env>.local.env` if you deliberately want to re-point the environment. |
| ACM cert stuck in `PENDING_VALIDATION` for a long time | Check the CNAME actually landed in Route 53: `aws route53 list-resource-record-sets --hosted-zone-id <id>`. DNS validation is usually fast but can occasionally take longer; the scripts' `wait certificate-validated` calls are safe to re-run. |
| `frontend/02-cloudfront.sh` or `destroy.sh`'s CloudFront step seems to hang | Not hanging — a distribution create/disable genuinely takes 5-15+ minutes to propagate to every edge location worldwide. This is CloudFront's own process, not something a script controls. |
| Target group shows the instance as `unhealthy` | SSH in via `aws ssm start-session --target <id>`, check `systemctl status order-pool-backend` and `journalctl -u order-pool-backend`. Common cause: `config/<env>.secrets.env` was never pushed (`backend/env-to-ssm.sh`) before the first deploy. |
| Backend can't reach Atlas / connection refused or times out | Check the EC2 instance's current public IP (`./status.sh <env>`) is actually on Atlas's Network Access list — see the Atlas section above about IPs changing if the instance is ever relaunched. |
| `deploy-backend.sh` reports a failed SSM command | It prints the remote script's stdout/stderr directly — read that first. If a previously-working release is now down, run `backend/rollback-backend.sh <env>`. |
| Registration succeeds but no verification email arrives | Check, in order: backend logs (`journalctl -u order-pool-backend`) for the nodemailer error; `./test/verify-dev.sh` for the 587 egress rule and SES identity status; whether the account is still in the SES **sandbox** (only verified recipients get mail — `./status.sh` shows it); the recipient's spam folder. |
| Backend logs `AccessDenied ... ses:SendRawEmail` | The From address doesn't match `SES_FROM_ADDRESS` (the IAM policy pins it) — the backend's `SMTP_FROM` must be the value `email/01-ses.sh` wrote. Re-run it, then `env-to-ssm.sh` and redeploy. |
| DNS not resolving yet after a Route 53 change | The scripts already wait for `INSYNC` on the change itself, but resolver caches elsewhere (your ISP, browser) can still lag. Check directly with `dig +short <domain>` against a public resolver: `dig @8.8.8.8 +short <domain>`. |

## 16. Destroying environments

```bash
./destroy.sh dev
```

Tears down everything `deploy.sh` created, in reverse dependency order, and requires typing the environment name itself (not just "yes") to confirm — this is the one command in the whole toolkit with that extra friction, because it's the one that's genuinely irreversible.

**Documented S3 policy**: the frontend site bucket, the project's only S3 bucket, is always emptied and then deleted. It holds nothing but rebuildable output (a Vite build) — there is no "keep the bucket" option, and `delete-bucket` refuses to run on a non-empty bucket regardless. Don't repurpose it for data you'd mind losing. The same goes for the ECR repository (deleted with its images, each rebuildable from its commit) and the CloudWatch log group (deleted with its logs).

Every teardown step tolerates the resource already being gone (a partial/interrupted destroy, or something removed by hand in the console) rather than hard-failing — re-running `destroy.sh` after any failure is always safe. It also wipes every SSM parameter under `/order-pool/<env>/` (state *and* secrets), so a destroyed environment doesn't leave an Atlas password sitting in Parameter Store.

`config/<env>.local.env` and `config/<env>.secrets.env` are deliberately left on disk after a destroy — delete them yourself if you're really done with that environment.

## 17. Estimated AWS cost (dev environment, us/eu region, rough)

| Resource | Approx. cost |
|---|---|
| EC2 `t3.small` (on-demand, running 24/7) | ~$15/month |
| Application Load Balancer | ~$18-20/month (hourly + LCU usage) |
| Public IPv4 addresses (the ALB's two, one per subnet, + the instance's) | ~$11/month ($0.005/hour each) |
| NAT Gateway | **$0** — deliberately not used, see architecture notes |
| ACM certificates | $0 (always free) |
| Route 53 hosted zone | ~$0.50/month + negligible query costs (assumes the zone already existed) |
| EBS root volume (12 GB gp3) | ~$1/month |
| S3 (frontend bucket) | Usage-based, negligible at this project's scale (a Vite build) |
| ECR (backend images) | ~$0.10/GB-month stored; the lifecycle policy keeps at most `ECR_KEEP_IMAGES` images (5 in dev; a few hundred MB, since they share layers), so cents |
| CloudWatch Logs | ~$0.50/GB ingested + ~$0.03/GB-month stored, `LOG_RETENTION_DAYS` retention (7 in dev) — cents at dev's volume |
| CloudFront | Usage-based; PriceClass_100 (NA/EU only) keeps it cheap, and the free tier covers meaningful traffic before any charge |
| MongoDB Atlas M0 | $0 (free tier) |
| Amazon SES | ~$0.10 per 1,000 emails sent from EC2 — effectively $0 at this project's volume |

Rough total for a `dev` environment left running continuously: **~$45-50/month**, dominated by the ALB (with its IPv4 addresses) and EC2, not by anything data-transfer-related. Running `./destroy.sh dev` between periods of active use (e.g. between demos) avoids paying for idle infrastructure — nothing here needs to stay up permanently just to preserve state, since all durable state is either in Atlas (external) or reproducible from `order-pools-app`/`order-pools-backend`'s own git history. Destroyed, dev costs only the Route 53 hosted zone (~$0.50/month): `destroy.sh` ends by listing anything still tagged with the environment (in its region and us-east-1), plus any unattached EBS volume or unassociated Elastic IP in the region, so a leftover shows up there rather than on the bill. While dev is destroyed, a push to `order-pools-backend` still runs its tests in CI, then skips the push and deploy with a warning.

## 18. Security considerations

- **No NAT Gateway; EC2 in a public subnet.** The security group is the sole network boundary: inbound allowed only from the ALB's security group (never a CIDR, never SSH), outbound limited to 443/tcp (HTTPS — SSM, ECR image pulls and their S3 layer downloads, CloudWatch Logs, Docker's apt repository), 587/tcp (SMTP submission with STARTTLS to AWS SES — see [Email (AWS SES)](#19-email-aws-ses)), 80/tcp (HTTP — Ubuntu's own default apt archives; required in practice, since the packages bootstrap installs and their dependencies (ca-certificates, curl, jq, Docker's dependencies) are served from Ubuntu's plain-HTTP mirrors — apt verifies package integrity via signed release indices regardless of transport, so this doesn't weaken package integrity), 27017/tcp (MongoDB's wire protocol — the actual Atlas data connection, distinct from the DNS lookup `mongodb+srv://` uses to find it), and DNS (53/tcp+udp) scoped to the VPC CIDR only. None of these are narrowed to a smaller CIDR than `0.0.0.0/0`, because neither Ubuntu's mirrors, Atlas's cluster nodes, nor SES's SMTP endpoint publish a small, stable IP range to pin instead — the real security boundary for Atlas is its own Network Access allow-list and DB credentials, not this security group. This trades one layer of defense-in-depth (no network path to the instance at all) for real monthly savings, on the premise that the security group is airtight. Revisit for an environment with a lower risk tolerance for that trade-off.
- **One long-lived AWS credential, by necessity: the SES SMTP key.** SES's SMTP interface only accepts credentials derived from an IAM user's access key — it can't use the instance role. `email/01-ses.sh` confines it to a dedicated IAM user whose only permission (via a group, per AWS's current guidance) is `ses:SendRawEmail` from exactly `SES_FROM_ADDRESS`, and it's stored only in the gitignored secrets file and an SSM `SecureString`. Rotate by re-running the script with the old key removed from the secrets file, then deleting the old key once redeployed.
- **No SSH, anywhere.** All administration is SSM Session Manager / Run Command, both authenticated via IAM, both leaving a CloudTrail-auditable record of who ran what — a meaningfully better audit story than SSH key access even setting aside the "no open port" benefit.
- **IMDSv2 enforced** (`HttpTokens=required`) on the instance, closing the classic SSRF-to-stolen-instance-credentials path IMDSv1 is vulnerable to.
- **Least-privilege IAM everywhere it was practical**: the EC2 instance role can only read its own SSM parameter path, pull its own ECR repository and write its own log group (`ecr:GetAuthorizationToken`, which has no resource to scope to, is the one `*`). The GitHub Actions OIDC roles are split three ways by concern (infra/frontend/backend) rather than one broad role.
- **Secrets never touch git or a Docker layer** — real values live only in SSM `SecureString` parameters, fetched at deploy time into a root-only `chmod 600` env file that the Docker daemon passes to the container, which runs as the image's unprivileged `node` user (never root). They're not in the image, so pulling it from ECR exposes none of them.
- **Single EC2 instance, in-place restart deploys.** No blue/green, no canary, no ASG — a deliberate, discussed trade-off for this project's current dev/demo stage (see [Backend deployment](#8-backend-deployment)). A failed deploy is a full outage on that one target until `rollback-backend.sh` runs; there is no redundancy to fail over to today.
- **`destroy.sh`'s bucket-emptying policy is irreversible by design** — see [Destroying environments](#16-destroying-environments).

## 19. Email (AWS SES)

The backend sends email (today: email-verification links, see `order-pools-backend`'s `auth/email-verification.ts`) with nodemailer over SMTP. In AWS that's **Amazon SES's SMTP interface**, set up by two scripts in `email/` — deliberately not part of `deploy.sh`, like `iam/02-github-oidc-roles.sh`: the first writes secrets into your local secrets file, and the second is a request reviewed by a person at AWS.

**`email/01-ses.sh <env>`** — idempotent, safe to re-run:

1. Creates a **domain identity** for `SES_DOMAIN` (`config/<env>.env`) with **Easy DKIM**, and publishes its three `_domainkey` CNAMEs to Route 53.
2. Sets a **custom MAIL FROM** subdomain (`SES_MAIL_FROM_DOMAIN`) and publishes its MX (to SES's regional feedback endpoint) and SPF TXT records, so SPF aligns with our domain for DMARC.
3. Publishes a monitor-only **DMARC** record (`p=none`) — *only if the domain has none*. Existing DMARC/MX/SPF records are never overwritten; the script warns instead.
4. Waits for SES to verify the domain (usually minutes; SES allows up to 72h — a timeout is a warning, re-run later).
5. Creates the IAM group `<project>-<env>-ses-senders` (policy: `ses:SendRawEmail` on this account's identities in this region, **only** with `ses:FromAddress = SES_FROM_ADDRESS`) and the user `<project>-<env>-ses-smtp` in it.
6. Mints an access key (unless the secrets file already holds this user's active key), derives the **SES SMTP password** from it locally with AWS's documented HMAC-SHA256 algorithm, and writes `SMTP_HOST`/`SMTP_PORT`/`SMTP_USER`/`SMTP_PASS`/`SMTP_FROM`/`SMTP_REPLY_TO` into `config/<env>.secrets.env`. The secret is never printed. If the file held other SMTP credentials, it asks before replacing them.

Then push and redeploy as usual: `./backend/env-to-ssm.sh <env>` and a backend deploy. The backend security group must allow **587/tcp outbound** (`security/01-security-groups.sh` does; re-run it on an existing environment to add the rule).

**The SES sandbox.** New SES accounts can only send *to verified addresses*, max 200/day. To test before leaving it, verify your own inbox: `aws sesv2 create-email-identity --email-identity you@example.com` (SES emails you a confirmation link). **`email/02-ses-production-access.sh <env>`** submits the production-access request (transactional mail, honest use-case description, asks for confirmation first); AWS usually answers within 24h and may ask follow-up questions (typically about bounce/complaint handling) in the AWS Support case it opens. Sandbox status is per account + region, not per environment.

**Sender vs. replies.** Mail goes out as `SES_FROM_NAME <SES_FROM_ADDRESS>` — a no-reply address on our own domain, because that's what SES can sign with DKIM and align for DMARC. Sending "from" a free-mail address (e.g. `@gmail.com`) through SES would fail that provider's DMARC checks and land in spam. Replies are routed to a real inbox instead with a `Reply-To: SES_REPLY_TO` header, which needs no SES verification.

**Region.** SES identities, quotas, sandbox status and SMTP passwords are all regional; everything here uses the environment's `AWS_REGION` (`eu-north-1` has an SES SMTP endpoint: `email-smtp.eu-north-1.amazonaws.com`).

**Teardown.** `destroy.sh` deletes the environment's SMTP IAM user (and its keys) and group — the credentials are environment-scoped. It deliberately **leaves the SES domain identity and its DNS records**: an identity belongs to the account + region, so another environment sending from the same domain would break if one environment's teardown deleted it. It costs nothing to keep; remove it by hand if you're done with the domain entirely.

**Not yet set up:** bounce and complaint handling (an SES configuration set + SNS notifications feeding a suppression step in the app). Worth adding before any real volume — repeated sends to bouncing addresses harm the account's sending reputation.

