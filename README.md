# 2VNC

2VNC creates preview environments for your work-in-progress software, within GitHub Issues/PRs — powered by Nix and Tailscale.

The usual preview environment only works well for web apps: open a pull request, ping the preview-related bot, get a temporary URL, click around in the browser. That breaks down when the thing you need to preview is a desktop app, a terminal UI, a local service, an admin tool, or something that only makes sense inside a full running machine.

2VNC makes those all feel like the same kind of preview.

You set up a private network called `staging`. Then every pull request can launch a temporary environment with its own private name, like:

```text
prv-1a2b3c4d-deadbeef.staging
```

Regardless of whether it's a web app, desktop app, or CLI, you access the preview via VNC, which provides a remote desktop environment. The preview is not on the public internet; it is only reachable from devices and users allowed by your Tailscale ACLs.

In practice, that means one preview flow can cover:

- web apps
- CLI tools
- desktop apps

Desktop app previews currently need to run on Linux. Windows and macOS support is planned.

## How It Works

2VNC has four pieces:

- **Tailscale** provides private network access to preview environments.
- **Ambit** wraps Fly.io (which hosts preview containers) so the `staging` network is exposed to Tailscale.
- **2VNC Nix** wraps your app into the VNC-accessible container image that Ambit runs for previews.
- **The GitHub Action** builds the preview from a pull request and deploys it to `*.staging`.

So the workflow is:

1. A pull request needs testing.
2. You comment:

```text
/preview ./projects/my-app#preview
```

3. GitHub builds and deploys that preview.
4. The action replies:

```text
Preview environment deployed: prv-1a2b3c4d-deadbeef.staging
```

5. You open the private address from your tailnet.

To tear it down:

```text
/preview stop prv-1a2b3c4d-deadbeef
```

## Setup

First create the Ambit network that backs your preview environments:

```bash
npx @cardelli/ambit auth login
npx @cardelli/ambit create staging --org personal --region lhr
npx @cardelli/ambit share staging group:team
```

Then add this workflow to the repository that should have preview environments:

```yaml
name: Preview

on:
  issue_comment:
    types: [created]

permissions:
  contents: read
  issues: write
  pull-requests: read

jobs:
  preview:
    if: github.event.issue.pull_request != null && startsWith(github.event.comment.body, '/preview')
    runs-on: ubuntu-latest

    steps:
      - uses: ToxicPine/2VNC@main
        with:
          github-token: ${{ github.token }}
          fly-api-token: ${{ secrets.FLY_API_TOKEN }}
          fly-private-network: staging
          fly-org: personal
          fly-region: lhr
```

Required GitHub secret:

- `FLY_API_TOKEN`

Optional repository variables:

- `FLY_PRIVATE_NETWORK`, default `staging`
- `FLY_ORG`, default `personal`
- `FLY_REGION`, default `lhr`

This repo includes the workflow at `.github/workflows/preview.yml` for its own previews.

## Add 2VNC To A Nix App

Expose a preview app with `mkPreviewApp`:

```nix
apps.${system}.preview = nix-vnc.lib.mkPreviewApp {
  run = {
    kind = "web";
    target = self.apps.${system}.default;
    web = {
      launch_url = "http://127.0.0.1:3000";
      browser = "chromium";
    };
  };

  vnc = {
    host = "0.0.0.0";
    port = 5900;
    unsafeAllowInsecureNonLocalhost = true;
  };
};
```

Supported targets:

- `web`: start an app and open Chromium or Firefox inside VNC
- `gui`: start a Linux desktop app inside VNC
- `cli`: open a shell in `xterm`

## Why No VNC Password?

The default model is private networking, not app-level passwords. The VNC service is reachable only over the Fly private network that Ambit bridges into Tailscale, and Tailscale ACLs decide who can connect.

See [docs/technical.md](docs/technical.md) for implementation details, action inputs, and the full architecture.
