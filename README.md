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

- **No NAT Gateway.** The backend EC2 instance sits in a *public* subnet with a direct route to the Internet Gateway, not a private subnet behind a NAT Gateway. The security group is the enforcement boundary instead (ALB-only inbound; outbound limited to 443/80/27017/tcp + DNS — see [Security considerations](#18-security-considerations) for exactly why each port is there) — this was a deliberate cost/complexity trade-off for a dev/demo-stage project (a NAT Gateway alone runs ~$40+/month).
- **In-place restart deploys**, not blue/green or canary. There's a single EC2 instance; deploying restarts the same process in place. A few seconds of downtime per deploy, and a failed deploy takes down the only target until rolled back. Deliberate, confirmed trade-off for this stage — see [Backend deployment](#8-backend-deployment).

**Resource dependency order** (what `deploy.sh` actually runs, in order):

```text
VPC -> Internet Gateway -> public subnets (2 AZs) -> route table
  -> security groups (ALB-SG, backend-SG)
  -> IAM (EC2 instance role + profile)
  -> EC2 instance
  -> artifact S3 bucket
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
- `node`/`npm` — not needed to provision infrastructure, but required for `backend/deploy-backend.sh` and `frontend/deploy-frontend.sh`, which build the actual applications.
- An AWS account with `aws configure` (or `AWS_PROFILE`) already working — verify with `aws sts get-caller-identity`.
- A Route 53 hosted zone already created for your domain (NS/SOA records set at your registrar) — this project uses subdomains within an existing zone, it doesn't create the zone itself.
- A MongoDB Atlas cluster — see [MongoDB Atlas](#14-mongodb-atlas). Not provisioned by this repo.

## 3. AWS account setup

The very first script you run for a given environment prints the caller's AWS account ID and **pins it** into `config/<env>.local.env` (gitignored). Every script run after that compares the live account against the pinned one and refuses to continue on a mismatch — this is the main defense against accidentally running `./destroy.sh prod` against the wrong AWS account because a different `AWS_PROFILE` happened to be exported. If you deliberately need to re-point an environment at a different account, delete that `.local.env` file.

## 4. Configuration

| File | Committed? | Purpose |
|---|---|---|
| `config/common.env` | Yes | Values shared by every environment (project name, tag keys) |
| `config/<env>.env` | Yes | Per-environment config: region, VPC/subnet CIDRs, instance type, domain names, Node major version |
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
./backend/env-to-ssm.sh dev                  # pushes them to SSM Parameter Store
./backend/deploy-backend.sh dev              # builds + ships order-pools-backend
./frontend/deploy-frontend.sh dev            # builds + ships order-pools-app
./status.sh dev                              # live health check of everything above
./test/verify-dev.sh dev                     # pass/fail assertions — see below
```

`deploy.sh` deliberately stops after infrastructure — it never builds or ships application code itself (see [GitHub Actions](#9-github-actions) for why that split matters).

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

`backend/01-ec2-instance.sh` launches a single Ubuntu 24.04 LTS instance (AMI resolved dynamically via Canonical's own SSM public parameter — never hardcoded) with a systemd unit installed but not started. `backend/deploy-backend.sh`:
1. Builds `order-pools-backend` locally (`npm ci && npm run build`).
2. Packages `package.json` + `package-lock.json` + `dist/` into a tarball — **deliberately no `node_modules`**. `bcrypt` is a native addon; installing it via `npm ci` *on the instance itself* (which `deploy-remote.sh.tmpl` does) is what guarantees the binary matches the instance's actual OS/architecture, rather than shipping one built on your laptop.
3. Uploads the tarball to a private S3 bucket, then sends an SSM command telling the instance to pull it down, install dependencies, write its `.env` from SSM Parameter Store, atomically swap the `releases/<timestamp>` → `current` symlink, and `systemctl restart`.
4. Polls the ALB target group until it reports healthy.

This is **pull-based**: the instance always initiates the S3 download and the parameter fetch over its own IAM role; nothing is ever pushed to it over SSH (there is no SSH — administration is SSM Session Manager only).

**Deploy strategy is in-place restart**, not blue/green or canary — confirmed deliberately for this project's dev/demo stage (see the architecture note above). `backend/rollback-backend.sh` re-points the `current` symlink at the previous release and restarts, for when a bad deploy needs undoing.

`KillSignal=SIGINT` in the systemd unit (not the default `SIGTERM`) matches `order-pools-backend/src/server.ts`, which only traps `SIGINT` for its graceful-shutdown path (closes the HTTP server + Mongo connection cleanly) — solved at the infrastructure layer instead of touching application code.

## 9. GitHub Actions

Implemented (Phase 6). `iam/02-github-oidc-roles.sh <env>` creates one OIDC identity provider (account-wide, once) and three separate IAM roles, each trusted only by its own repo + this specific environment (via the token's `repository`/`environment` claims, not long-lived AWS access keys):

```text
order-pool-<env>-infra-deploy      -> broad (creates/destroys the whole stack); trusted by order-pools-infrastructure
order-pool-<env>-frontend-deploy   -> scoped to the frontend S3 bucket + CreateInvalidation; trusted by order-pools-app
order-pool-<env>-backend-deploy    -> scoped to the artifact bucket + ssm:SendCommand on Project/Environment-tagged
                                       instances + read of /order-pool/<env>/state/backend/* and .../backend/*;
                                       trusted by order-pools-backend
```

The `infra-deploy` role uses AWS managed "FullAccess" policies for the services it provisions (EC2/ELB/S3/CloudFront/Route53/ACM/SSM) — a deliberate simplification for this project's scale, documented as such rather than silently glossed over. IAM itself is the one exception: `infra-deploy`'s IAM permissions are hand-scoped to only the `order-pool-*-ec2-role`/`-ec2-profile` resources `iam/01-ec2-instance-role.sh` creates, explicitly excluding the three OIDC deploy roles and the OIDC provider itself — granting a CI role broad IAM access is a well-known self-privilege-escalation path, so that's the one place "FullAccess" was never on the table.

**Workflows**, one per repo:

- `order-pools-infrastructure/.github/workflows/infra.yml` — manual (`workflow_dispatch`), runs `deploy.sh`/`destroy.sh` against a chosen environment. No push trigger: infra changes are rare and higher-risk than app deploys.
- `order-pools-backend/.github/workflows/deploy.yml` — builds and tests the app (own checkout, own `npm ci`/`npm test`/`npm run build`), packages the same no-`node_modules` tarball `deploy-backend.sh` does, uploads it to S3, then calls a **reusable workflow** defined in `order-pools-infrastructure/.github/workflows/deploy-backend.yml` to do the actual render/SSM-send/poll mechanics.
- `order-pools-app/.github/workflows/deploy.yml` — fully self-contained: build (with `VITE_API_BASE_URL` injected the same way `deploy-frontend.sh` does), `s3 sync` (two-pass cache headers), CloudFront invalidation, no cross-repo call.

**Why the backend calls a reusable workflow but the frontend doesn't, even though both mirror a local script**: reusable workflows (`on: workflow_call`) are GitHub's sanctioned way to share workflow logic across private repos owned by the same account, without a PAT or deploy key — unlike a plain `actions/checkout` of a different repo, which the default `GITHUB_TOKEN` can never do regardless of ownership. The backend's deploy mechanics (render a template, send an SSM command, poll its status, poll target-group health) are substantial enough that duplicating them into `order-pools-backend`'s own workflow would be a real drift risk. The frontend's remaining logic after "build" is a handful of straightforward `aws s3`/`aws cloudfront` calls — small enough that the added indirection of a cross-repo call would cost more clarity than the duplication it avoids, which would cut against this project's own explicit "don't hide AWS CLI commands behind unnecessary abstraction" learning goal. Build itself (`npm ci`/`npm run build`) is inherently repo-local either way and was never a candidate for centralizing — it can only ever run where the app's own source is checked out.

Each repo needs these set as **environment variables** (not secrets — none of these are sensitive) under Settings → Environments → `<env>` → Variables, printed at the end of `iam/02-github-oidc-roles.sh`'s output, or set directly with `gh variable set NAME --env <env> --body VALUE --repo <owner>/<repo>`:

| Repo | Variables |
|---|---|
| `order-pools-infrastructure` | `INFRA_DEPLOY_ROLE_ARN`, `AWS_REGION` |
| `order-pools-app` | `FRONTEND_DEPLOY_ROLE_ARN`, `AWS_REGION`, `BACKEND_DOMAIN` |
| `order-pools-backend` | `BACKEND_DEPLOY_ROLE_ARN`, `AWS_REGION`, `BACKEND_PORT` |

A GitHub Actions runner resolves AWS resource IDs exactly the way your laptop does — `aws ssm get-parameter --name /order-pool/<env>/state/backend/instance-id`, etc. — which is the entire reason those IDs live in SSM Parameter Store as the canonical copy (`lib/state.sh`) rather than only in a local, gitignored cache file a runner could never see.

**Worth verifying empirically before relying on it for anything real** (noted honestly rather than asserted with more confidence than warranted): that same-account private-repo reusable-workflow calls work exactly as described here with zero extra configuration. This is documented GitHub behavior, but it's a comparatively less-common corner of Actions — Phase 7's end-to-end test should include a trivial dry run of the reusable-workflow call specifically, before trusting it for a real deploy.

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
3. **Network Access**: allow-list the backend EC2 instance's public IP — get it from `./status.sh <env>` (row "EC2 public IP") or the output of `backend/01-ec2-instance.sh`. This is the instance's *own* public IP, not a NAT Gateway Elastic IP, because this project has no NAT Gateway (see [Security considerations](#18-security-considerations)). It stays stable for the life of a running instance, but **will change if the instance is ever terminated and relaunched** — re-check and update Atlas's allow-list if that happens.
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
| DNS not resolving yet after a Route 53 change | The scripts already wait for `INSYNC` on the change itself, but resolver caches elsewhere (your ISP, browser) can still lag. Check directly with `dig +short <domain>` against a public resolver: `dig @8.8.8.8 +short <domain>`. |

## 16. Destroying environments

```bash
./destroy.sh dev
```

Tears down everything `deploy.sh` created, in reverse dependency order, and requires typing the environment name itself (not just "yes") to confirm — this is the one command in the whole toolkit with that extra friction, because it's the one that's genuinely irreversible.

**Documented S3 policy**: both S3 buckets (frontend site, backend artifacts) are always emptied and then deleted. Neither is meant to hold anything but rebuildable output (a Vite build, release tarballs) — there is no "keep the bucket" option, and `delete-bucket` refuses to run on a non-empty bucket regardless. Don't repurpose either bucket for data you'd mind losing.

Every teardown step tolerates the resource already being gone (a partial/interrupted destroy, or something removed by hand in the console) rather than hard-failing — re-running `destroy.sh` after any failure is always safe. It also wipes every SSM parameter under `/order-pool/<env>/` (state *and* secrets), so a destroyed environment doesn't leave an Atlas password sitting in Parameter Store.

`config/<env>.local.env` and `config/<env>.secrets.env` are deliberately left on disk after a destroy — delete them yourself if you're really done with that environment.

## 17. Estimated AWS cost (dev environment, us/eu region, rough)

| Resource | Approx. cost |
|---|---|
| EC2 `t3.small` (on-demand, running 24/7) | ~$15/month |
| Application Load Balancer | ~$18-20/month (hourly + LCU usage) |
| NAT Gateway | **$0** — deliberately not used, see architecture notes |
| ACM certificates | $0 (always free) |
| Route 53 hosted zone | ~$0.50/month + negligible query costs (assumes the zone already existed) |
| S3 (both buckets) | Usage-based, negligible at this project's scale (a Vite build + a handful of release tarballs) |
| CloudFront | Usage-based; PriceClass_100 (NA/EU only) keeps it cheap, and the free tier covers meaningful traffic before any charge |
| MongoDB Atlas M0 | $0 (free tier) |

Rough total for a `dev` environment left running continuously: **~$35-40/month**, dominated by the ALB and EC2, not by anything data-transfer-related. Running `./destroy.sh dev` between periods of active use (e.g. between demos) avoids paying for idle infrastructure — nothing here needs to stay up permanently just to preserve state, since all durable state is either in Atlas (external) or reproducible from `order-pools-app`/`order-pools-backend`'s own git history.

## 18. Security considerations

- **No NAT Gateway; EC2 in a public subnet.** The security group is the sole network boundary: inbound allowed only from the ALB's security group (never a CIDR, never SSH), outbound limited to 443/tcp (HTTPS — SSM, apt's NodeSource source, npm), 80/tcp (HTTP — Ubuntu's own default apt archives; required in practice, since GPG-signed dependencies of packages installed at bootstrap, e.g. NodeSource's nodejs .deb pulling in libatomic1/gcc-14, are served from Ubuntu's plain-HTTP mirrors — apt verifies package integrity via signed release indices regardless of transport, so this doesn't weaken package integrity), 27017/tcp (MongoDB's wire protocol — the actual Atlas data connection, distinct from the DNS lookup `mongodb+srv://` uses to find it), and DNS (53/tcp+udp) scoped to the VPC CIDR only. None of these are narrowed to a smaller CIDR than `0.0.0.0/0`, because neither Ubuntu's mirrors nor Atlas's cluster nodes publish a small, stable IP range to pin instead — the real security boundary for Atlas is its own Network Access allow-list and DB credentials, not this security group. This trades one layer of defense-in-depth (no network path to the instance at all) for real monthly savings, on the premise that the security group is airtight. Revisit for an environment with a lower risk tolerance for that trade-off.
- **No SSH, anywhere.** All administration is SSM Session Manager / Run Command, both authenticated via IAM, both leaving a CloudTrail-auditable record of who ran what — a meaningfully better audit story than SSH key access even setting aside the "no open port" benefit.
- **IMDSv2 enforced** (`HttpTokens=required`) on the instance, closing the classic SSRF-to-stolen-instance-credentials path IMDSv1 is vulnerable to.
- **Least-privilege IAM everywhere it was practical**: the EC2 instance role can read only its own SSM parameter path and its own artifact bucket, never `*`. The (planned) GitHub Actions OIDC roles are split three ways by concern (infra/frontend/backend) rather than one broad role.
- **Secrets never touch git or a Docker layer** — real values live only in SSM `SecureString` parameters, fetched at deploy time and written to a `chmod 600` file owned by a dedicated, unprivileged `orderpool` system user (never root).
- **Single EC2 instance, in-place restart deploys.** No blue/green, no canary, no ASG — a deliberate, discussed trade-off for this project's current dev/demo stage (see [Backend deployment](#8-backend-deployment)). A failed deploy is a full outage on that one target until `rollback-backend.sh` runs; there is no redundancy to fail over to today.
- **`destroy.sh`'s bucket-emptying policy is irreversible by design** — see [Destroying environments](#16-destroying-environments).
