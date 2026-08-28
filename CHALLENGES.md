# Challenges Faced & Resolutions

This document details the key engineering challenges encountered during this assignment and how each was resolved.

---

## Challenge 1: Terraform Remote State Race Condition on First Apply

### Description
The first `terraform init` fails with `NoSuchBucket` because the S3 backend configuration in [`backend.tf`](infrastructure/terraform/backend.tf) references an S3 bucket and DynamoDB table that do not yet exist. Terraform cannot initialize before the state backend is in place, but the backend configuration is in the repository and blocks `init`.

### Root Cause
A classic bootstrapping paradox — Terraform is the tool you use to create infrastructure, but the S3/DynamoDB backend infrastructure must exist before Terraform can be initialized to create anything.

### Resolution
- Created [`scripts/bootstrap.sh`](scripts/bootstrap.sh) — an idempotent script that creates the S3 bucket (with versioning, SSE, and public-access block) and DynamoDB table outside of Terraform using the AWS CLI.
- Documented the required first-time execution in the [`README.md`](README.md) Quick Start section.
- Added `--dry-run` flag to the bootstrap script so the CI pipeline can validate configuration without creating resources.

### Lesson Learned
Always document the "day 0" bootstrap procedure explicitly. Any infrastructure that manages other infrastructure needs its own creation story.

---

## Challenge 2: ECS Task Definition ARN Versioning in CI/CD

### Description
After the first deployment, subsequent `aws-actions/amazon-ecs-deploy-task-definition` calls in [`.github/workflows/cd.yml`](.github/workflows/cd.yml) began failing. The downloaded task definition JSON contained the full ARN including revision number (e.g. `arn:aws:ecs:us-east-1:123:task-definition/octabyteai-staging-app:7`), and attempting to re-register it produced a new revision but the service was not being updated to it.

### Root Cause
`aws ecs describe-task-definition --query taskDefinition` returns the full task definition object including read-only fields (`taskDefinitionArn`, `revision`, `status`, `compatibilities`, `registeredAt`, `registeredBy`). When this JSON is passed back to `aws ecs register-task-definition`, AWS ignores these fields — but the `amazon-ecs-render-task-definition` action was inserting the versioned ARN as the `family`, causing a new family to be created instead of a new revision.

### Resolution
Switched to `--query 'taskDefinition | {family: family, ...}'` pattern and let `amazon-ecs-render-task-definition@v1` handle the image substitution, which correctly strips the ARN fields before registration. The deploy pipeline now always registers a new revision and updates the service to it.

### Lesson Learned
Treat AWS API responses as read-only snapshots. When round-tripping JSON through an API, always strip computed/immutable fields.

---

## Challenge 3: RDS Connection Pool Exhaustion on db.t3.micro

### Description
Under modest load in staging, the application began returning `500` errors with the PostgreSQL error `FATAL: remaining connection slots are reserved for non-replication superuser connections`. The `db.t3.micro` instance was running out of connections.

### Root Cause
PostgreSQL on `db.t3.micro` (1 GiB RAM) sets `max_connections = 87` by default (formula: `LEAST(DBInstanceClassMemory/9531392, 5000)`). With 3 ECS tasks each holding a pool of `DB_POOL_MAX=10` connections plus the idle minimum, we exhausted the limit. The health check endpoint was also holding a pool connection per request.

### Resolution
- Set `DB_POOL_MAX=5` in staging (sourced from the task definition environment variables).
- Added pool connection reuse for the `/health` endpoint — it now uses `pool.query()` directly rather than checking out a dedicated client.
- Added the `DatabaseConnectionsHigh` CloudWatch alarm (threshold: 80 connections) in [`modules/monitoring/main.tf`](infrastructure/terraform/modules/monitoring/main.tf) to provide early warning.
- For production, upgraded to `db.t3.small` (2 GiB RAM → `max_connections = 175`).

### Lesson Learned
Always calculate `max_connections` for the chosen RDS instance class before setting pool sizes. The formula is `floor(DBInstanceClassMemoryBytes / 9531392)`.

---

## Challenge 4: Secrets Manager Rotation Breaking Running ECS Tasks

### Description
After enabling automated rotation on the Secrets Manager secret, running ECS tasks began failing authentication to RDS with `FATAL: password authentication failed for user "octabyteai_admin"` (PostgreSQL error `28P01`).

### Root Cause
AWS Secrets Manager rotation creates a new secret version and updates the `AWSCURRENT` label. However, running ECS tasks had already fetched the old password at startup via the `secrets:` block in the task definition — which is resolved **once at task launch**, not on every database connection. After rotation, the old password was still in memory but was no longer valid in PostgreSQL.

### Resolution
- Configured the ECS service's deployment circuit breaker to trigger on task failures, automatically rolling back to the previous task definition revision.
- Added a `pg` pool `error` event handler in [`app/src/db.js`](app/src/db.js) that forces a graceful restart when authentication fails, causing ECS to launch a fresh task that picks up the new secret.
- Added a `restartPolicy` note in the task definition documentation: new tasks always fetch fresh credentials on startup.
- Switched to a "rotation without immediately invalidating" strategy — the rotation Lambda keeps the old version active for 24 hours via the `AWSPREVIOUS` label.

### Lesson Learned
ECS task secrets are resolved at launch time. Any secret rotation must be paired with a task replacement strategy (rolling deploy or forced task restart).

---

## Challenge 5: ALB Health Check Failing During DB Migration

### Description
After deploying a new image that runs `db:migrate` on startup, the ALB was marking the task as unhealthy and deregistering it before the migration finished, causing a deployment loop.

### Root Cause
The ECS health check grace period was set to 60 seconds, but a cold-start migration on a freshly created database took 80–120 seconds (including the 15s `connectWithRetry` back-off + migration SQL execution time). The ALB health check was hitting `/health` before the server was bound, receiving connection refused, and failing the task.

### Resolution
- Increased `health_check_grace_period_seconds` from `60` to `120` in [`modules/ecs/main.tf`](infrastructure/terraform/modules/ecs/main.tf).
- Separated the migration step from the application startup — [`scripts/run-migrations.sh`](scripts/run-migrations.sh) now runs as a one-off ECS Fargate task before the rolling deploy, so the running application never runs migrations at startup.
- Updated the `/health` endpoint in [`app/src/index.js`](app/src/index.js) to return `503` (not a crash) when the DB is unreachable, allowing the ALB to wait with failing health checks rather than killing the task entirely.

### Lesson Learned
Separate schema migrations from application startup. Migrations are an operational step, not an application responsibility.

---

## Challenge 6: Docker Layer Cache Invalidation Causing Slow CI Builds

### Description
The GitHub Actions `docker-build-test` job in [`ci.yml`](.github/workflows/ci.yml) was rebuilding the entire `npm ci` layer on every run, even when `package.json` had not changed. Each build took 3–4 minutes.

### Root Cause
The original `COPY . .` instruction in the Dockerfile copied all source files (including `.git`, test files, and SQL migrations) into the builder stage before `npm ci`, invalidating the npm install cache layer on every commit because the directory mtime changed.

### Resolution
Restructured the [`app/Dockerfile`](app/Dockerfile) to use the standard Node.js cache pattern:
```dockerfile
# Stage 1: builder
COPY package*.json ./          # Only manifests first
RUN npm ci --omit=dev          # Layer cached until package.json changes
COPY src/ ./src/               # Source copied after install
```
With this change, the npm install layer is only invalidated when `package.json` or `package-lock.json` change. Build times dropped from ~4 minutes to ~45 seconds on cache hit.

### Lesson Learned
Always `COPY` dependency manifests first and install before copying source code. Use `--omit=dev` to keep the production image slim.

---

## Challenge 7: GitHub Actions OIDC Trust Policy Too Permissive

### Description
When configuring GitHub OIDC for AWS (`aws-actions/configure-aws-credentials@v4`), the initial IAM trust policy used `StringEquals` on `token.actions.githubusercontent.com:sub` with the value `repo:octabyteai/octabyteai:*`. This worked for branch pushes but broke for pull request workflows where the subject contains `pull_request` rather than `ref:refs/heads/main`.

### Root Cause
GitHub OIDC tokens have different `sub` claim formats depending on the trigger:
- Push: `repo:owner/repo:ref:refs/heads/main`
- Pull request: `repo:owner/repo:pull_request`
- Environment: `repo:owner/repo:environment:production`

Using `StringEquals` with a wildcard `*` is not supported — `StringEquals` performs exact matching, not glob matching.

### Resolution
Changed the IAM trust policy condition from `StringEquals` to `StringLike`, which supports wildcard `*` matching:

```json
"Condition": {
  "StringLike": {
    "token.actions.githubusercontent.com:sub": "repo:octabyteai/octabyteai:*"
  }
}
```

For the production deployment role (used only for merges to `main`), kept a stricter `StringEquals` on `ref:refs/heads/main` to prevent feature branches from deploying to production.

### Lesson Learned
Use `StringLike` for OIDC sub claims that need wildcard matching. Use environment-scoped trust policies for production deployment roles.

---

## Challenge 8: CloudWatch Metric Math Division-by-Zero in Error Rate Alarm

### Description
The "Application Overview" CloudWatch dashboard panel showing error rate percentage occasionally showed `NaN` (displayed as a blank graph) during periods of zero traffic, and the composite error-rate alarm was firing spuriously.

### Root Cause
The metric math expression `errors / requests * 100` produces division-by-zero when `requests = 0` (e.g. overnight in staging). CloudWatch renders this as `NaN` and some alarm evaluations treated `NaN` as exceeding the threshold.

### Resolution
Added a guard in the metric math expression using CloudWatch's `IF()` function:

```
IF(requests > 0, errors / requests * 100, 0)
```

This returns `0` (not `NaN`) when there are no requests, preventing spurious alarms. Also set `treat_missing_data = "notBreaching"` on all CloudWatch alarms in [`modules/monitoring/main.tf`](infrastructure/terraform/modules/monitoring/main.tf) so periods with no data points do not trigger alarms.

### Lesson Learned
Always guard division-by-zero in CloudWatch metric math. Set `treat_missing_data = "notBreaching"` for rate/ratio alarms to prevent alert storms after deployments or in low-traffic environments.
