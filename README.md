# Use fuse and nix to globally share Mathlib

This template project provides Lean toolchains managed by nix, and Mathlib(stored in /nix/store) is shared via fuse-overlayfs.

Ensure to enable fuse by adding `programs.fuse.enable = true` (recently set to be disable by default) in your configuration.

Since toolchains are managed by nix, you should avoid conflicting with system wide elan when, e.g., using VSCode Lean extension.
