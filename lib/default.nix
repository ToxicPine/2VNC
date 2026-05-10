{ self }:
let
  localhostHosts = [ "127.0.0.1" "localhost" "::1" ];

  isDerivation = x: builtins.isAttrs x && x ? type && x.type == "derivation";
  isApp = x: builtins.isAttrs x && x ? type && x.type == "app" && x ? program;

  mainProgram = drv: drv.meta.mainProgram or drv.pname or drv.name;
in {
  mkPreviewApp = { run, vnc ? {} }:
    let
      system = builtins.currentSystem;
      pkgs = import <nixpkgs> { inherit system; };
      lib = pkgs.lib;

      runKind = run.kind or (throw "run.kind is required");
      _ = if builtins.elem runKind [ "web" "gui" "cli" ] then true else throw "run.kind must be one of: web, gui, cli";

      target = run.target or (throw "run.target is required");
      targetProgram =
        if builtins.isString target then target
        else if isApp target then target.program
        else if isDerivation target then "${target}/bin/${mainProgram target}"
        else throw "run.target must be a flake app, runnable derivation, or explicit program path";

      browserName = if runKind == "web" then run.web.browser or (throw "run.web.browser is required when run.kind=web") else null;
      _browserCheck = if runKind != "web" || builtins.elem browserName [ "chromium" "firefox" ] then true else throw "run.web.browser must be chromium or firefox";
      launchUrl = if runKind == "web" then run.web.launch_url or (throw "run.web.launch_url is required when run.kind=web") else null;
      browserPackage = if runKind == "web" then (run.web.browserPackage or (if browserName == "chromium" then pkgs.chromium else pkgs.firefox)) else null;

      shellCandidate = if runKind == "cli" then (run.cli.shell or pkgs.bashInteractive) else null;
      shellProgram = if runKind == "cli" then (if builtins.isString shellCandidate then shellCandidate else "${shellCandidate}/bin/${mainProgram shellCandidate}") else null;

      width = vnc.width or 1440;
      height = vnc.height or 1000;
      host = vnc.host or "127.0.0.1";
      port = vnc.port or 5900;
      unsafeAllowInsecureNonLocalhost = vnc.unsafeAllowInsecureNonLocalhost or false;

      sec = if (vnc ? security) && vnc.security != null then vnc.security else {};
      credentials = sec.credentials or null;
      x509 = sec.x509 or null;
      rsa = sec.rsa or null;
      hasCredentials = credentials != null;
      hasX509 = x509 != null;
      hasRsa = rsa != null;

      _authChoice =
        let n = lib.length (lib.filter (x: x) [ hasCredentials hasX509 hasRsa ]);
        in if n <= 1 then true else throw "security auth material is mutually exclusive: choose exactly one of credentials, x509, rsa";

      credUserEnv = if hasCredentials && credentials ? username then credentials.username.env or null else null;
      credPassEnv = if hasCredentials && credentials ? password then credentials.password.env or null else null;
      _credCheck = if !hasCredentials || credPassEnv != null then true else throw "security.credentials.password.env is required";

      x509CertEnv = if hasX509 && x509 ? cert then x509.cert.env or null else null;
      x509KeyEnv = if hasX509 && x509 ? key then x509.key.env or null else null;
      x509UserEnv = if hasX509 && x509 ? username then x509.username.env or null else null;
      x509PassEnv = if hasX509 && x509 ? password then x509.password.env or null else null;
      _x509BaseCheck = if !hasX509 || (x509CertEnv != null && x509KeyEnv != null) then true else throw "security.x509.cert.env and security.x509.key.env are required";
      _x509UserCheck = if !hasX509 || x509UserEnv == null || x509PassEnv != null then true else throw "security.x509.username.env requires security.x509.password.env";

      rsaKeyEnv = if hasRsa && rsa ? key then rsa.key.env or null else null;

      inferredType =
        if hasCredentials then (if credUserEnv == null then "TLSVnc" else "TLSPlain")
        else if hasX509 then (
          if x509UserEnv == null && x509PassEnv == null then "X509None"
          else if x509UserEnv == null && x509PassEnv != null then "X509Vnc"
          else "X509Plain"
        )
        else if hasRsa then "RA2"
        else "None";

      securityTypes = sec.types or [ inferredType ];

      typeCompatible = t:
        if builtins.elem t [ "None" "TLSNone" ] then !(hasCredentials || hasX509 || hasRsa)
        else if builtins.elem t [ "VncAuth" "TLSVnc" ] then hasCredentials && credPassEnv != null && credUserEnv == null
        else if builtins.elem t [ "Plain" "TLSPlain" ] then hasCredentials && credUserEnv != null && credPassEnv != null
        else if t == "X509None" then hasX509 && x509CertEnv != null && x509KeyEnv != null && x509UserEnv == null && x509PassEnv == null
        else if t == "X509Vnc" then hasX509 && x509CertEnv != null && x509KeyEnv != null && x509UserEnv == null && x509PassEnv != null
        else if t == "X509Plain" then hasX509 && x509CertEnv != null && x509KeyEnv != null && x509UserEnv != null && x509PassEnv != null
        else if builtins.elem t [ "RA2" "RA2ne" "RA2_256" "RA2ne_256" ] then hasRsa
        else throw "Unsupported security type: ${t}";

      _typesCompat = if lib.all typeCompatible securityTypes then true else throw "security.types is incompatible with selected auth material";

      unauthenticated = lib.any (t: builtins.elem t [ "None" "TLSNone" ]) securityTypes;
      _insecureGuard =
        if unauthenticated && !(builtins.elem host localhostHosts) && !unsafeAllowInsecureNonLocalhost
        then throw "Unauthenticated VNC on non-localhost is blocked; set vnc.unsafeAllowInsecureNonLocalhost = true to override"
        else true;

      launcher = pkgs.writeShellApplication {
        name = "nix-vnc-preview";
        runtimeInputs = [ pkgs.tigervnc pkgs.xterm pkgs.jq pkgs.coreutils pkgs.fira-code ] ++ lib.optional (runKind == "web") browserPackage;
        text = ''
          set -euo pipefail

          export DISPLAY=:99
          XDG_RUNTIME_DIR="$(mktemp -d)"
          export XDG_RUNTIME_DIR
          cleanup() {
            [ -n "''${VNC_PID:-}" ] && kill "$VNC_PID" 2>/dev/null || true
            [ -n "''${RUN_PID:-}" ] && kill "$RUN_PID" 2>/dev/null || true
            [ -n "''${PASSFILE:-}" ] && rm -f "$PASSFILE" || true
            rm -rf "$XDG_RUNTIME_DIR"
          }
          trap cleanup EXIT

          security_csv='${lib.concatStringsSep "," securityTypes}'
          EXTRA_ARGS=("-SecurityTypes" "$security_csv" "-localhost" "${if builtins.elem host localhostHosts then "yes" else "no"}" "-rfbport" "${toString port}" "-geometry" "${toString width}x${toString height}")

          if [ "$security_csv" = "TLSVnc" ] || [ "$security_csv" = "VncAuth" ]; then
            pass_var='${if credPassEnv == null then "" else credPassEnv}'
            test -n "$pass_var" || { echo "Missing configured password env name" >&2; exit 1; }
            test -n "''${!pass_var:-}" || { echo "Missing env var $pass_var" >&2; exit 1; }
            PASSFILE="$(mktemp)"
            printf '%s' "''${!pass_var}" | vncpasswd -f > "$PASSFILE"
            chmod 600 "$PASSFILE"
            EXTRA_ARGS+=("-PasswordFile" "$PASSFILE")
          fi

          Xvnc "$DISPLAY" "''${EXTRA_ARGS[@]}" &
          VNC_PID=$!
          sleep 1

          ${if runKind == "gui" then ''${targetProgram} & RUN_PID=$!'' else if runKind == "web" then ''
            ${targetProgram} &
            RUN_PID=$!
            sleep 1
            ${if browserName == "chromium" then ''
              CHROMIUM_GPU_FLAGS=(--ozone-platform=x11)
              if [ ! -e /dev/dri/card0 ] && [ ! -e /dev/dri/renderD128 ]; then
                CHROMIUM_GPU_FLAGS+=(--disable-gpu)
              fi
              ${browserPackage}/bin/chromium --no-first-run --new-window "''${CHROMIUM_GPU_FLAGS[@]}" "${launchUrl}" >/dev/null 2>&1 &
            '' else ''${browserPackage}/bin/firefox --new-window "${launchUrl}" >/dev/null 2>&1 &''}
          '' else ''xterm -fa "Fira Mono" -fs 11 -geometry 140x40 -e ${shellProgram} & RUN_PID=$!''}

          jq -n \
            --arg vnc "vnc://${host}:${toString port}" \
            --arg host "${host}" \
            --argjson port ${toString port} \
            --argjson securityTypes '${builtins.toJSON securityTypes}' \
            '{vnc:$vnc,host:$host,port:$port,securityTypes:$securityTypes}'

          wait "$VNC_PID"
        '';
      };
    in
    { type = "app"; program = "${launcher}/bin/nix-vnc-preview"; };
}
