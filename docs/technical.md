# Technical Notes

This document covers the mechanics behind 2VNC. The README stays focused on the value and day-to-day usage.

## Architecture

2VNC is designed to sit on top of Ambit.

Ambit creates a Fly.io private network, deploys a router into it, joins that router to Tailscale, advertises the Fly private subnet, and configures split DNS. If the Fly private network is named `staging`, workloads are reachable on `*.staging` from devices allowed by Tailscale ACLs.

2VNC provides the runtime wrapper for workloads that need visual access:

- starts `Xvnc`
- starts the requested target inside the VNC display
- optionally opens Chromium or Firefox for web apps
- prints connection metadata as JSON

The GitHub Action connects the pieces:

1. Parse `/preview ./path#app` or `/preview stop <name>`.
2. Verify the command came from a trusted PR participant.
3. Check out the pull request head commit.
4. Run `nix bundle --bundler github:NixOS/bundlers#toDockerImage`.
5. Push the resulting image to `registry.fly.io`.
6. Create a Fly app on the configured private network.
7. Run `flyctl deploy --no-public-ips` with the built image.
8. Reply to the PR with the private preview address.

## Action Inputs

- `github-token`: required; used for PR checkout and comments
- `fly-api-token`: required; used by Fly, image push, and Ambit
- `fly-private-network`: optional; default `staging`
- `fly-org`: optional; default `personal`
- `fly-region`: optional; default `lhr`
- `command`: optional; defaults to the PR comment body
- `require-trusted-author`: optional; default `true`

## Action Outputs

- `mode`: `start`, `stop`, or `invalid`
- `preview-app`: generated app name, for example `prv-1a2b3c4d-deadbeef`
- `preview-address`: private address, for example `prv-1a2b3c4d-deadbeef.staging`

## Command Validation

Start commands must look like this:

```text
/preview ./path/to/flake#app
```

The action rejects targets containing `..` or `--`, and only accepts relative installables shaped like `./path#app`.

Stop commands must use generated preview names:

```text
/preview stop prv-1a2b3c4d-deadbeef
```

## Security Model

2VNC assumes the preview workload is private because it is deployed onto a Fly private network that Ambit has bridged into Tailscale. The access boundary is Tailscale plus Tailscale ACLs.

For VNC previews, `unsafeAllowInsecureNonLocalhost = true` is expected when binding on `0.0.0.0`. It tells `mkPreviewApp` that the caller is intentionally relying on private network access control instead of VNC password authentication.

## `mkPreviewApp`

`mkPreviewApp` accepts:

```nix
{
  run = {
    kind = "web" | "gui" | "cli";
    target = <flake app, derivation, or program path>;
  };
  vnc = { ... };
}
```

For `web`, set:

```nix
run.web = {
  launch_url = "http://127.0.0.1:3000";
  browser = "chromium"; # or "firefox"
};
```

For `cli`, optionally set:

```nix
run.cli.shell = pkgs.bashInteractive;
```

Useful VNC options:

- `vnc.host`, default `127.0.0.1`
- `vnc.port`, default `5900`
- `vnc.width`, default `1440`
- `vnc.height`, default `1000`
- `vnc.unsafeAllowInsecureNonLocalhost`, default `false`

## Notes

The current workflow deploys the bundled image directly with `flyctl deploy --no-public-ips`. Ambit is not invoked by the action; it is the setup-time tool that creates and bridges the Fly private network.
