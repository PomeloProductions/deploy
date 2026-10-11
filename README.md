# Pomelo Deploy

Tenant-facing deploy tooling for the Pomelo client-driver controller. This is
how an org's CI (or a developer's laptop) hands an OCI image off to the
platform and watches it roll out.

## What this is

`apps/deploy/` ships three things that tenants will consume from the outside:

- a thin **bash CLI** (`pomelo deploy …`) that POSTs a gzipped image tarball
  to the controller (a single async call that returns a deploy id and chains
  the push + deploy server-side), then **polls the deploy's status** to a
  terminal outcome while showing logs best-effort;
- a **composite GitHub Action** (`PomeloProductions/deploy@v1`)
  that wraps the CLI in two YAML steps so a tenant workflow is ~6 lines;
- a small **installer** (`install.sh`) for non-GitHub CIs and laptops.

Everything is a thin wrapper over the controller's HTTP API. There is no
controller embedded in the CLI — it just takes a tarball and a token and talks
to whatever URL you point it at. The same binary works against staging and
production controllers; the URL changes, the rest doesn't.

> **v1 implementation note.** The CLI is currently bash, because that's the
> fastest path to a working surface that we can test against the real
> controller. A Go binary is on the roadmap; when it ships, the CLI flags,
> exit codes, and the `install.sh` URL all stay the same — only the bytes
> behind the curl change.

## Getting started

1. **Mint a deploy token.** Sign in to your org's dashboard on the controller
   (`https://controller.driver.pomelo.io`, or the URL your Pomelo contact gave
   you), open **Apps → \<your app\> → Deploy tokens**, and create one. Tokens
   start with `pkd_`. Treat them like passwords; if one leaks, revoke it from
   the same screen.
2. **Get your org + app slugs.** Same dashboard, top of the app page. Both are
   lowercase, dash-separated (`equity-creative`, `cnh-merchandising`).
3. **Pick your integration.** GitHub Actions tenants use the composite Action
   below. Everyone else installs the CLI and calls it from their CI step.

## GitHub Actions usage

```yaml
# .github/workflows/deploy.yml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build image
        run: docker build -t my-app:${{ github.sha }} .

      - name: Save to tarball
        run: docker save my-app:${{ github.sha }} | gzip > image.tar.gz

      - name: Deploy to Pomelo
        uses: PomeloProductions/deploy@main
        with:
          url:     ${{ secrets.POMELO_URL }}
          token:   ${{ secrets.POMELO_TOKEN }}
          service: 42            # numeric Service id (preferred)
          image:   ./image.tar.gz
```

Pin to a release tag (`@v1`) in production instead of `@main`.

### Deploy targets: `service` (preferred) vs `org`/`app` (deprecated)

There are two ways to address what you're deploying:

- **`service` (preferred).** A numeric id of an org-owned **Service** record.
  The Service carries its own Kubernetes deploy target (namespace, deployment,
  container, env secret) and image repository, so this works for *any* app —
  including ones that don't follow the `namespace == app-slug` /
  `{slug}-api` / container `api` naming convention (e.g. a FastAPI service in
  `org-3-lingwave` with deployment `lingwave-api-fastapi` / container
  `fastapi`). The deploy token must be scoped to that service's org (and, for
  a service-scoped token, that service).

- **`org` + `app` (deprecated).** The original slug-based path. The controller
  derives the target from the slug: namespace `{app}`, deployment `{app}-api`,
  container `api`, secret `{app}-env`. Kept working for existing apps that
  already follow that convention. Prefer `service` for anything new.

Set `service` **or** the `org`+`app` pair — if `service` is present it wins.

A complete copy lives in [`templates/github-actions.yml`](templates/github-actions.yml).

## GitLab CI usage

```yaml
stages: [build, deploy]

build:
  stage: build
  image: docker:24
  services: [docker:24-dind]
  script:
    - docker build -t my-app:$CI_COMMIT_SHORT_SHA .
    - docker save my-app:$CI_COMMIT_SHORT_SHA | gzip > image.tar.gz
  artifacts:
    paths: [image.tar.gz]

deploy:
  stage: deploy
  image: alpine:3.20
  before_script:
    - apk add --no-cache bash curl jq
    - curl -fsSL https://raw.githubusercontent.com/PomeloProductions/deploy/v1/install.sh | bash
  script:
    - >
      pomelo deploy
      --url   "$POMELO_URL"
      --token "$POMELO_TOKEN"
      --org   equity-creative
      --app   cnh-merchandising
      --image ./image.tar.gz
```

Full template: [`templates/gitlab-ci.yml`](templates/gitlab-ci.yml).

## CircleCI usage

```yaml
version: 2.1

jobs:
  build-and-deploy:
    docker: [{image: cimg/base:current}]
    steps:
      - checkout
      - setup_remote_docker: {version: 24.0.9}
      - run: docker build -t my-app:${CIRCLE_SHA1} . && docker save my-app:${CIRCLE_SHA1} | gzip > image.tar.gz
      - run:
          name: Install Pomelo CLI
          command: |
            sudo apt-get update && sudo apt-get install -y jq
            curl -fsSL https://raw.githubusercontent.com/PomeloProductions/deploy/v1/install.sh | bash
      - run:
          name: Deploy
          command: |
            pomelo deploy --url "$POMELO_URL" --token "$POMELO_TOKEN" \
                          --org equity-creative --app cnh-merchandising \
                          --image ./image.tar.gz

workflows:
  deploy: { jobs: [build-and-deploy] }
```

Full template: [`templates/circleci-config.yml`](templates/circleci-config.yml).

## Jenkins usage

```groovy
stage('Deploy to Pomelo') {
    environment {
        POMELO_URL   = credentials('pomelo-url')
        POMELO_TOKEN = credentials('pomelo-token')
    }
    steps {
        sh '''
            docker save my-app:${GIT_COMMIT} | gzip > image.tar.gz
            curl -fsSL https://raw.githubusercontent.com/PomeloProductions/deploy/v1/install.sh \
              | bash -s -- --to "$WORKSPACE/.pomelo-bin"
            "$WORKSPACE/.pomelo-bin/pomelo" deploy \
              --url "$POMELO_URL" --token "$POMELO_TOKEN" \
              --org equity-creative --app cnh-merchandising \
              --image ./image.tar.gz
        '''
    }
}
```

Full snippet: [`templates/jenkinsfile-snippet`](templates/jenkinsfile-snippet).

## Local laptop usage

Useful for one-off deploys, hotfixes, or testing the platform end-to-end
without going through CI.

```bash
# 1. Install the CLI once
curl -fsSL https://raw.githubusercontent.com/PomeloProductions/deploy/v1/install.sh | bash

# 2. Build & save your image
docker build -t my-app:dev .
docker save my-app:dev | gzip > image.tar.gz

# 3. Deploy
export POMELO_URL=https://controller.driver.pomelo.io
export POMELO_TOKEN=pkd_xxxxxxxxxxxxxxxxxxxxxxxxxxxx
pomelo deploy \
  --org   equity-creative \
  --app   cnh-merchandising \
  --image ./image.tar.gz
```

Pass `--no-wait` to return as soon as the deploy starts instead of streaming
logs to completion.

> **`--env-file` is deprecated / ignored.** The upload is now asynchronous and
> no longer accepts env in the request. Manage deploy-time environment through
> the controller's per-service secrets store (synced on provision). The flag is
> still accepted (and warns) so old workflows don't break.

## API reference

The CLI wraps **two** HTTP endpoints: an asynchronous upload, and the deploy
logs/status SSE stream (which it polls for the current status). If you want to
call them directly — debugging, alternative tooling, etc. — here's the contract.

The upload endpoint has a **service-id** form (preferred) and a **legacy
org/app** form. They are equivalent except the service form resolves the K8s
target from the Service record; pick whichever matches how the token was
minted.

### 1. Upload an image (async — this IS the deploy)

The upload is asynchronous. The endpoint streams the tarball to a shared
staging volume, hands it to a queued job on the controller's worker (which does
the skopeo push to GHCR and then **chains the deploy**), and returns **202
immediately** — before the (potentially minutes-long) push. This avoids the
load-balancer idle-timeout `504` that a synchronous push hit on fat images.
There is **no separate "create a deploy" call**.

```
# preferred:
POST /v1/services/{service}/images
# deprecated:
POST /v1/organizations/{organization}/apps/{app}/images

  Authorization: Bearer pkd_…
  Content-Type:     application/octet-stream
  Content-Encoding: gzip
  body: gzipped OCI image tarball

→ 202 Accepted
  { "deploy_id": "dep_01H…", "status": "pending",
    "logs_url":  "/v1/deploys/dep_01H…/logs" }
```

The service form pushes to the Service's configured `image_repository` (or, if
unset, the global `<base>/<slug>` convention). The final `image_ref`
(`…:sha-<digest>`) is computed server-side and recorded on the deploy; it is
NOT in the 202 response (the digest isn't known until the worker inspects the
archive).

```bash
curl --fail -X POST \
  -H "Authorization: Bearer $POMELO_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  -H "Content-Encoding: gzip" \
  --data-binary @image.tar.gz \
  "$POMELO_URL/v1/services/42/images"
```

### 2. Wait for the outcome — poll the deploy's STATUS (source of truth)

Follow the `deploy_id` from the 202 response over the same SSE endpoint:

```
GET /v1/deploys/{deploy_id}/logs
  Authorization: Bearer pkd_…
  Accept: text/event-stream

→ SSE stream. The FIRST data frame on every connect is a connect-time status
  snapshot carrying the deploy's CURRENT status, then history + live events:
  data: {"event_type":"status_changed","message":"current status: rolling_out","metadata":{"new_status":"rolling_out","snapshot":true}}
  data: {"event_type":"log","message":"Image received; queued for push","metadata":{…}}
  data: {"event_type":"status_changed","message":"rolling_out → ready","metadata":{"new_status":"ready"}}
  event: done
  data: {}
```

The deploy advances `pending → pushing_to_ghcr → updating_k8s → rolling_out →
ready` (or `→ failed`; or `→ available` for a gated build awaiting promotion).
The terminal set is `ready` (success), `failed` and `available` (both non-zero).

**How the CLI decides the outcome: it polls the status, it does NOT trust the
log stream.** Every time the controller accepts a connection on this endpoint it
emits, as the very first flushed frame, a synthetic `status_changed` snapshot
(`metadata.new_status`, `metadata.snapshot:true`) carrying the deploy's current
status — served with `X-Accel-Buffering: no`. The CLI therefore treats a *short*
connect as a status probe: connect, read that one authoritative frame, close. It
repeats this every `POMELO_POLL_INTERVAL` seconds and **exits 0 the moment a
probe reports `ready`**, non-zero on `failed`/`available`, and only times out
(non-zero) if the status is still non-terminal after `POMELO_POLL_TIMEOUT`.

> There is a dedicated JSON status endpoint, `GET /v1/deploys/{deploy_id}`, but
> it is **JWT-only** — it rejects the `pkd_…` deploy token the CLI holds. So the
> snapshot-bearing logs endpoint is the only status channel a deploy token can
> read, and the short-probe pattern above turns it into an effective status poll.

The log stream is otherwise shown **best-effort only**: a separate long-lived
connection tails the events for visibility and reconnects if it drops, but its
health never affects the exit code. This is the fix for the long-standing
"successful deploy reports red" bug — previously the outcome was read off a
single long-lived stream, so a stream that stalled, was proxy-buffered, or hit
an idle timeout ran out the clock and failed the run even though the rollout had
reached `ready`. Now only the deploy's actual status can fail (or pass) the run.

> This README and `cli/pomelo-deploy.sh` are the single source of truth for the
> contract — it's defined in one place in the CLI and is straightforward to
> update.

## Troubleshooting

**`401 Unauthorized` on upload.**  Token is missing, revoked, or scoped to a
different org/app. Re-mint from the dashboard.

**`403 Forbidden` on upload.**  The token lacks the `images:write` scope for
the target org/service. Talk to your org admin or re-issue with the right
scope. (The upload now chains the deploy server-side, so a single
`images:write`-scoped token drives the whole flow.)

**`413 Payload Too Large`.**  Image exceeds the controller's upload limit.
Slim the image (multi-stage build, prune dev deps) or ask Pomelo to raise the
limit for your app.

**`pomelo: command not found` after install.**  The installer fell back to
`~/.local/bin` because `/usr/local/bin` wasn't writable. Add `~/.local/bin`
to your `PATH` or re-run with `sudo bash install.sh`.

**Live logs cut out / the stream stalls before the deploy reaches `ready`.**
This does **not** fail the run. The outcome is decided by polling the deploy's
status, not by the log stream, so a dropped/stalled/buffered stream only means
fewer logs on screen — the status poll still observes `ready` and exits 0. The
CLI keeps polling up to `POMELO_POLL_TIMEOUT` (default 900s) and reports failure
only on an explicit `failed`/`available` status or on exhausting that budget. If
a healthy rollout is legitimately slower than the budget, raise
`POMELO_POLL_TIMEOUT`; the deploy keeps running server-side regardless and can be
re-attached at `/v1/deploys/{deploy_id}/logs`.

Tuning knobs (env vars): `POMELO_POLL_TIMEOUT` (total wait, default 900s),
`POMELO_POLL_INTERVAL` (seconds between status polls, default 3s),
`POMELO_CONNECT_TIMEOUT` (per-connect `curl --max-time`, default 120s),
`POMELO_RECONNECT_DELAY` (delay between live-log reconnects, default 2s),
`POMELO_LIVE_LOGS` (set `0` to poll silently without the live log tail).

**`jq: command not found`.**  Install it: `apt-get install jq` /
`brew install jq` / `apk add jq`. The installer warns about this at install
time.

## CI templates

Drop-in starting points lives in [`templates/`](templates/):

- [`github-actions.yml`](templates/github-actions.yml)
- [`gitlab-ci.yml`](templates/gitlab-ci.yml)
- [`circleci-config.yml`](templates/circleci-config.yml)
- [`jenkinsfile-snippet`](templates/jenkinsfile-snippet)
- [`buildkite-step.yml`](templates/buildkite-step.yml)
