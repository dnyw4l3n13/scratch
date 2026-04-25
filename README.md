# scratch

NanoClaw's sanity / sacrificial test target.

NanoClaw's per-spawn startup self-check (`container/startup-check.sh` in
the nanoclaw repo) and the build-time sanity in its `Dockerfile` both
clone this repo to verify outbound HTTPS / SSH + GPG-signed commits work.
A daily workflow (`.github/workflows/cleanup-sanity.yml`) prunes the
`sanity-runs/**` branches each container leaves behind.

## What lives here

| File | Purpose |
|------|---------|
| `container-smoke-test.sh` | Standalone harness for the agent container's `/app/startup-check.sh`. Run this locally to verify a freshly-built nanoclaw-agent image without going through nanoclaw's full message-routing path. |

The startup-check itself lives in the nanoclaw repo at
`container/startup-check.sh` — that's the source-of-truth, baked into
the agent container image. The script in this repo is the wrapper that
invokes it standalone.

## Usage

```bash
# Defaults: most recent local nanoclaw-agent image, auto-detect ~/nanoclaw,
# no OneCLI env (the 2 OneCLI checks will fail in this mode).
./container-smoke-test.sh

# Pin a specific image and forward host's OneCLI gateway env:
./container-smoke-test.sh --image nanoclaw-agent-v2-117d18c5:latest --with-onecli

# Keep the temp /workspace dir afterwards so you can read the outbound.db
# message that startup-check posted:
./container-smoke-test.sh --keep-workspace

# Full help:
./container-smoke-test.sh --help
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0  | Every check passed |
| 42 | At least one check failed (matches `startup-check.sh`) |
| 2  | Usage error or no image found |
