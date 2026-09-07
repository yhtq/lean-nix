{
  description = "CLAI — Lean 4 project using nixpkgs leanPackages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem =
        { pkgs, ... }:
        let
          projectSrc = ./.;
        in
        {
          packages.mathlib = pkgs.leanPackages.mathlib;
          packages.mathlibDeps = pkgs.linkFarm "lean4-mathlib-deps" (
            map
              (name: {
                inherit name;
                path = pkgs.leanPackages.${name};
              })
              [
                "mathlib"
                "plausible"
                "LeanSearchClient"
                "importGraph"
                "proofwidgets"
                "aesop"
                "Qq"
                "batteries"
                "Cli"
              ]
          );

          # `buildLakePackage` currently triggers Lake to write native artifacts
          # into the read-only Mathlib store path (nixpkgs#550523). Elaborating
          # the project still verifies all Lean imports without that invalid write.
          packages.default =
            pkgs.runCommand "CLAI-0.1.0"
              {
                nativeBuildInputs = with pkgs.leanPackages; [
                  lean4
                  mathlib
                ];
              }
              ''
                lean ${projectSrc}/Main.lean
                mkdir -p "$out"
                cp -r ${projectSrc}/. "$out/"
              '';

          apps.linkLakeDeps = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "link-lake-deps";
                runtimeInputs = [
                  pkgs.nix
                  pkgs.coreutils
                  pkgs.findutils
                ];
                text = ''
                  if [ ! -f flake.nix ] || [ ! -f lake-manifest.json ]; then
                    echo "Run this command from the CLAI project root." >&2
                    exit 1
                  fi

                  nix build .#mathlibDeps --out-link .lake/nix-deps
                  mkdir -p .lake/packages

                  # Each package directory is its own copy-on-write overlay.
                  # Sources and prebuilt Lean artifacts remain links into the
                  # Nix store; native `.c.o.export` files are written locally.
                  for package in mathlib plausible LeanSearchClient importGraph proofwidgets aesop Qq batteries Cli; do
                    destination=".lake/packages/$package"
                    if [ -L "$destination" ]; then
                      rm "$destination"
                    fi
                    if [ ! -e "$destination" ]; then
                      package_store="$(readlink -f ".lake/nix-deps/$package")"
                      mkdir -p "$destination"
                      cp -as "$package_store"/. "$destination"
                    fi
                    if [ ! -d "$destination" ]; then
                      echo "Expected package directory: $destination" >&2
                      exit 1
                    fi

                    # `cp -a` preserves the store's read-only directory modes.
                    # Alter directories only; linked files stay immutable.
                    find "$destination" -type d -exec chmod u+rwx {} +
                    if [ -d "$destination/.lake/build/ir" ]; then
                      find "$destination/.lake/build/ir" -type l -name '*.c.o.export' -delete
                    fi
                  done
                '';
              }
            }/bin/link-lake-deps";
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs.leanPackages; [
              lean4
              mathlib
            ];
          };
        };
    };
}
