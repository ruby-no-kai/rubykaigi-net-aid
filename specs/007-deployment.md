# 007-deployment

## Summary

Production infrastructure and delivery: Rails on AWS Lambda for web requests and background jobs (ActiveJob on SQS), Aurora DSQL, S3 and CloudFront for the frontend and cached bootstrap payloads, `nwa.rubykaigi.org` routing including `/<tag>`, secrets, and the deploy pipeline on GitHub Actions. Infrastructure is managed with Terraform.

## Motivation

- The app is used a few weeks a year intensively and idles the rest. Lambda and DSQL scale to zero cost when idle and need no patching between Episodes.
- DSQL authenticates with IAM tokens and has no connection limit to manage, which suits many short-lived Lambda environments (`backend/config/initializers/dsql_token.rb` already generates tokens).
- The QR codes on every asset label point at `https://nwa.rubykaigi.org/<tag>`. That URL has to keep working for the life of the labels.
- The SPA and the API must share one origin (005), so one CloudFront distribution fronts both.
- Branch copies (003), imports (012) and exports (013) run longer than a request, so jobs need a worker.

## Explanation

### Shape

```
viewer ──> CloudFront nwa.rubykaigi.org
             ├─ /rubykaigi.net_aid.*/*, /auth/*, /up ──> Lambda function URL: netaid-web-prd (Rails)
             ├─ /_ui/*                                 ──> S3 netaid-frontend-prd (hashed assets, long cache)
             ├─ /_bootstrap/*                          ──> S3 netaid-bootstrap-prd (frozen branch payloads, signed)
             └─ default                                ──> S3 index.html (SPA routes, /<tag>)

netaid-web-prd ──enqueue──> SQS netaid-jobs-prd ──> netaid-lambdakiq-prd (Rails, ActiveJob)
netaid-runner-prd  (db:migrate, one-off commands)
all functions ──IAM token──> Aurora DSQL cluster
```

### Deploying

- Merge to `main` triggers `.github/workflows/deploy.yml`:
  1. Build the backend image (`backend/Dockerfile`), push to ECR tagged with the commit SHA.
  2. Update `netaid-runner-prd`, run `bin/rails db:migrate` (psqldef) through `deploy/lambrunner.rb`.
  3. Update `netaid-lambdakiq-prd`, then `netaid-web-prd`.
  4. `pnpm build` in `frontend/`, sync `dist/` to the frontend bucket (`/_ui/` assets first, `index.html` last), invalidate `/index.html`.
- One deploy at a time (`concurrency: production`).
- Rollback: re-run `update-function-code` with the previous image tag; re-sync the previous frontend build from its artefact.

### One-off commands

```sh
BUNDLE_GEMFILE=deploy/Gemfile bundle exec deploy/lambrunner.rb netaid-runner-prd bin/rails runner 'Episode.count'
```

### Environments

- `prd` only. Development runs locally against PostgreSQL (`docs/coder/database.md`).
- TODO(interview): a `stg` environment with its own DSQL cluster for testing imports and migrations against real DSQL? Proposed: no persistent stg; per-developer schemas on the prd cluster as `/sorah-guides:dsql-on-rails` describes, if needed.

## Drawbacks

- Lambda function URLs buffer responses (6 MB each way, no streaming). Bootstrap of a live branch must be paginated (004), and the change feed cannot stream (006 polls).
- Cold starts boot Rails; the first request after idle takes seconds.
- Jobs are limited to 15 minutes per invocation, so branch copies must be chunked and chained (003).
- Two deploy targets (image and static files) can drift for a moment during a deploy; the SPA must tolerate an API one version ahead.

## Considered Alternatives

- ECS Fargate with Puma: always-on cost for an app idle most of the year. The same image still runs Puma, so moving is possible.
- Aurora Serverless v2 PostgreSQL: closer to standard PostgreSQL, but has a minimum capacity cost and connection management issues on Lambda. The domain model is already shaped around DSQL limits.
- API Gateway HTTP API instead of a function URL: adds cost and a 30 s limit without features we need.
- Separate origins for SPA (`nwa.rubykaigi.org`) and API (`api.nwa...`): needs CORS and weakens `ConnectForgeryProtection`.

## Prior Art

- himari (`rubykaigi-net/tf/himari`): Lambda function URL behind CloudFront with `X-Forwarded-Host`, `*.rubykaigi.net` certificate, logs to `rk-aws-logs`.
- sponsor-app (`rubykaigi-net/tf/sponsor-app`, `sponsor-app/deploy/lambrunner.rb`): Rails app deploy with a runner function.
- `/sorah-guides:rails-on-lambda`: the three-function layout, `SSM_SECRET__` loading, CloudFront origin verification, deploy order.

## Security and Privacy Considerations

- Function URL `authorization_type = "NONE"`, protected by a random `x-origin-verify` header that CloudFront adds and `Apigatewayv2Rack::Middlewares::CloudfrontVerify` checks; the secret lives in SSM as `CLOUDFRONT_VERIFY`.
- `CloudfrontXff` middleware so `request.remote_ip` is the viewer's.
- S3 buckets private, read through CloudFront OAC only.
- Bootstrap payloads for frozen branches contain whole branches. They are served only with CloudFront signed URLs (or signed cookies) issued by the API to signed-in viewers, short-lived. TODO(interview): signed URLs per file vs. a signed cookie for `/_bootstrap/*`? Proposed: signed URL returned by `SyncService.Bootstrap` for frozen branches.
- Secrets (`SECRET_KEY_BASE`, himari client secret, CloudFront verify, CloudFront signing key) in SSM Parameter Store, loaded by `config/lambda_boot.rb`; no `master.key` in the image. TODO(interview): `backend/config/credentials.yml.enc` exists from `rails new`; drop it in favour of SSM only? Proposed: yes.
- IAM:
  - `NetAidApp` execution role: DSQL `dsql:DbConnect` for the app role (not admin), SQS send/receive on the job queue, S3 write on the bootstrap bucket, `ssm:GetParameters` on its parameters, `sts:AssumeRole`/sts-cat usage for the GitHub export (013).
  - `NetAidDeploy` role for GitHub Actions (OIDC, `main` branch and `production` environment only): ECR push, `lambda:UpdateFunctionCode`/`GetFunctionConfiguration` on the three functions, `lambda:InvokeFunction` on the runner, S3 write on the frontend bucket, CloudFront invalidation.
  - Schema changes run as DSQL `admin` from the runner only. TODO(interview): separate runner role with `dsql:DbConnectAdmin`, so web and jobs never get admin? Proposed: yes.
- CloudFront response headers policy: HSTS, CSP from 005, `X-Content-Type-Options`, `Referrer-Policy`.

## Mission Scope

### Out of scope

- Monitoring and alerting beyond log retention and a DLQ alarm. TODO(interview): Sentry? Proposed: add later.
- Backups beyond DSQL's built-in (AWS Backup for DSQL can be added later).
- The GitHub App or sts-cat configuration for opening PRs (013).
- himari client registration details (001), apart from the redirect URL.

### Expected Outcomes

- Terraform for all resources, applied.
- `https://nwa.rubykaigi.org/` serves the SPA, signs in through himari, and calls the API.
- `https://nwa.rubykaigi.org/rk-aph26a3` opens the asset (once 014 exists; the routing is in place now).
- A push to `main` deploys backend and frontend with migrations.
- Jobs run on SQS through Lambdakiq.

## Implementation Plan

### Where the Terraform lives

- TODO(interview): `rubykaigi-net/tf/net-aid/` alongside himari and sponsor-app, or `tf/` in this repository? Proposed: `rubykaigi-net/tf/net-aid/`, state `s3://rk-infra/terraform/net-aid.tfstate`, region `ap-northeast-1`, matching the other apps.

### Terraform files

| File | Resources |
|---|---|
| `aws.tf`, `backend.tf`, `versions.tf` | providers (`ap-northeast-1`, `us-east-1` alias for CloudFront/ACM), default tags `Project=net-aid` |
| `dsql.tf` | `aws_dsql_cluster` `netaid-prd` (single region, deletion protection) |
| `ecr.tf` | `aws_ecr_repository` `netaid`, lifecycle keeping the last N images |
| `lambda.tf` | `netaid-web-prd`, `netaid-lambdakiq-prd`, `netaid-runner-prd` (image, arm64, entrypoint `/lambda_entrypoint.sh`, `APP_HANDLER`), function URL on web, SQS event source mapping (`batch_size = 1`, `ReportBatchItemFailures`), log groups with retention |
| `sqs.tf` | `netaid-jobs-prd` (visibility 301 s), `netaid-jobs-prd-dlq` (`maxReceiveCount = 13`) |
| `s3.tf` | `netaid-frontend-prd`, `netaid-bootstrap-prd` (private, OAC policies) |
| `cloudfront.tf` | distribution `nwa.rubykaigi.org`, behaviours above, origin custom headers `X-Forwarded-Host` and `x-origin-verify`, `Managed-AllViewerExceptHostHeader` for the API, `Managed-CachingDisabled` for the API, `Managed-CachingOptimized` for `/_ui/*`, CloudFront Function rewriting SPA paths to `/index.html`, key group for signed bootstrap URLs |
| `acm.tf`, `route53.tf` | certificate for `nwa.rubykaigi.org` in us-east-1, alias records A/AAAA in the `rubykaigi.org` zone |
| `ssm.tf` | parameters (values set out of band), `random_password` for the origin verify secret |
| `iam_NetAidApp.tf`, `iam_NetAidDeploy.tf` | roles above |
| `locals.tf`, `variables.tf` | shared environment (`RAILS_ENV`, `JOB_ADAPTER=lambdakiq`, `LAMBDAKIQ_QUEUE`, `DSQL_ENDPOINT`, `SSM_SECRET__*`, `WEB_CONCURRENCY=0`, `RAILS_MAX_THREADS=1`), `initial_image_uri` |

- Path routing: `/rubykaigi.net_aid.*` is the Connect path prefix (`/<package>.<Service>/<Method>`). TODO(interview): put RPCs under `/api/` instead, for a simpler CloudFront rule and SPA route space? Proposed: keep Connect's default paths, matched by `/rubykaigi.net_aid.*`.
- `/<tag>` and other SPA paths fall through to the default behaviour; the CloudFront Function serves `index.html` for any path without a file extension.

### Backend changes

- Gems: `apigatewayv2_rack`, `lambdakiq`, `aws_lambda_ric` (`require: false`), `aws-sdk-ssm`.
- Files from `/sorah-guides:rails-on-lambda` references: `config/lambda_entrypoint.sh`, `config/docker_entrypoint.sh`, `config/lambda_boot.rb`, `config/lambda_rack.rb`, `config/lambda_runner.rb`, `config/initializers/active_job.rb`, `config/initializers/lambdakiq.rb`, `config.ru` middlewares, `deploy/lambrunner.rb`, `deploy/Gemfile`.
- `backend/Dockerfile`: switch the workdir and entrypoints to the Lambda layout, link `tmp/` to `/tmp`, precompile bootsnap, write `REVISION`. Keep psqldef in the image for `db:migrate`.
- `config/environments/production.rb`: `assume_ssl`, `force_ssl`, stdout logging, host `nwa.rubykaigi.org`.
- Scheduled work (e.g. stale outbox reports, Fleet snapshots) through EventBridge Scheduler invoking the runner. None needed yet.

### CI/CD

- `.github/workflows/ci.yml` and `_test.yml`: rspec, Sorbet, rubocop, `buf lint`, generated-code drift, frontend typecheck/test/build. Not strictly part of this spec, but deploy depends on it. TODO(interview): separate spec for CI? Proposed: here.
- `.github/workflows/deploy.yml`: on push to `main` after `_test.yml`; jobs `build-image` (`docker/build-push-action`, `provenance: false`, `sbom: false`, arm64), `deploy-backend`, `deploy-frontend`. Actions pinned by SHA, `permissions: {}` at top, `id-token: write` per job, environment `production`.

## Current Status

Draft: rough content populated, not yet reviewed. Interview not started.

Open questions:
- From 001 review: the app and API move to `aid.rubykaigi.net`; `nwa.rubykaigi.org` stays only for asset-label QR codes and redirects `/<tag>` into the app. No CORS. himari clients `net-aid`, `net-aid-local`, `net-aid-cli`; `NET_AID_MACHINE_ROLES` from SSM.
- Terraform location (`rubykaigi-net/tf/net-aid` vs this repo)
- staging environment
- signed URLs vs signed cookies for frozen bootstrap payloads
- Connect paths vs `/api/` prefix for CloudFront routing
- dropping `credentials.yml.enc`
- separate runner role with DSQL admin
- CI workflow scope and Sentry
