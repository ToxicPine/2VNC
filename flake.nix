{
  description = "Lean Nix flake library for raw VNC preview apps";

  outputs = { self }: {
    lib = import ./lib { inherit self; };
  };
}
