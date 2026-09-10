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
          projectSrc = pkgs.lib.cleanSourceWith {
            src = ./.;
            filter =
              path: type:
              pkgs.lib.cleanSourceFilter path type
              && builtins.baseNameOf path != ".lake"
              && builtins.baseNameOf path != "result";
          };
          packageNames = [
            "mathlib"
            "plausible"
            "LeanSearchClient"
            "importGraph"
            "proofwidgets"
            "aesop"
            "Qq"
            "batteries"
            "Cli"
          ];
        in
        {
          packages.mathlib = pkgs.leanPackages.mathlib;
          packages.mathlibDeps = pkgs.linkFarm "lean4-mathlib-deps" (
            map (name: {
              inherit name;
              path = pkgs.leanPackages.${name};
            }) packageNames
          );

          # nixpkgs#550523 prevents buildLakePackage from writing native Lake
          # artifacts into immutable dependency paths. This still verifies all
          # project imports against the nixpkgs-provided Mathlib.
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

          apps.mountLakeDeps = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "mount-lake-deps";
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.fuse-overlayfs
                  pkgs.util-linux
                ];
                text = ''
                  packages=(mathlib plausible LeanSearchClient importGraph proofwidgets aesop Qq batteries Cli)
                  if [ ! -f flake.nix ] || [ ! -f lake-manifest.json ]; then
                    echo "Run this command from the CLAI project root." >&2
                    exit 1
                  fi

                  nix build .#mathlibDeps --out-link .lake/nix-deps
                  mkdir -p .lake/packages .lake/fuse-upper .lake/fuse-work .lake/fuse-logs

                  for package in "''${packages[@]}"; do
                    mountpoint=".lake/packages/$package"
                    upper=".lake/fuse-upper/$package"
                    work=".lake/fuse-work/$package"

                    if mountpoint -q "$mountpoint"; then
                      echo "Already mounted: $mountpoint"
                      continue
                    fi
                    if [ -L "$mountpoint" ]; then
                      rm "$mountpoint"
                    fi
                    if [ -e "$mountpoint" ] && [ ! -e "$upper" ]; then
                      mv "$mountpoint" "$upper"
                    elif [ -e "$mountpoint" ] && [ -e "$upper" ]; then
                      if [ -n "$(find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
                        echo "Both $mountpoint and $upper contain data; refusing to discard artifacts." >&2
                        exit 1
                      fi
                      rmdir "$mountpoint"
                    fi

                    packageStore="$(readlink -f ".lake/nix-deps/$package")"
                    mkdir -p "$upper" "$mountpoint"
                    # Remove old file-level COW links. The FUSE lowerdir will
                    # provide those files directly; upperdir keeps local output.
                    find "$upper" -type l -delete
                    # FUSE copy-up retains Nix store's 0555 directory mode. A
                    # writable upperdir skeleton prevents compiler write errors
                    # without copying any source or prebuilt Lean artifacts.
                    find "$packageStore" -type d -print0 | while IFS= read -r -d $'\0' directory; do
                      relative="''${directory#"$packageStore"/}"
                      if [ "$directory" = "$packageStore" ]; then
                        chmod u+rwx "$upper"
                      else
                        mkdir -p "$upper/$relative"
                        chmod u+rwx "$upper/$relative"
                      fi
                    done

                    rm -rf "$work"
                    mkdir -p "$work"
                    export PATH=/run/wrappers/bin:$PATH
                    nohup fuse-overlayfs \
                      -o "lowerdir=$packageStore,upperdir=$upper,workdir=$work" \
                      "$mountpoint" > ".lake/fuse-logs/$package.log" 2>&1 &
                    for _ in 1 2 3 4 5; do
                      mountpoint -q "$mountpoint" && break
                      sleep 1
                    done
                    if ! mountpoint -q "$mountpoint"; then
                      cat ".lake/fuse-logs/$package.log" >&2 || true
                      echo "Failed to mount $mountpoint" >&2
                      exit 1
                    fi
                  done
                '';
              }
            }/bin/mount-lake-deps";
          };

          apps.unmountLakeDeps = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "unmount-lake-deps";
                runtimeInputs = [
                  pkgs.fuse3
                  pkgs.util-linux
                ];
                text = ''
                  for package in mathlib plausible LeanSearchClient importGraph proofwidgets aesop Qq batteries Cli; do
                    mountpoint=".lake/packages/$package"
                    if mountpoint -q "$mountpoint"; then
                      fusermount3 -u "$mountpoint"
                    fi
                  done
                '';
              }
            }/bin/unmount-lake-deps";
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              leanPackages.lean4
              leanPackages.mathlib
              fuse-overlayfs
            ];
          };
        };
    };
}
