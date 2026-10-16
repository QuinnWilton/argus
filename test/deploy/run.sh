#!/bin/sh
# Runs test/deploy/check.sh in a container of SYSTEM (debian, alpine or
# nixos), with Rust installed in it or not (RUST: none or present), on
# ELIXIR (1.19, the default, on OTP 28; 1.20 on OTP 29; Debian and Alpine
# only), the checkout mounted read-only. The deploy workflow's Linux jobs
# run this; it runs anywhere Docker does, for the architecture of the host.
#
#   test/deploy/run.sh SYSTEM RUST [ELIXIR]
set -eu

system=$1
rust=$2
elixir=${3:-1.19}
src=$(cd "$(dirname "$0")/../.." && pwd)

case $system in
  debian)
    image=elixir:$elixir
    prep=:
    if [ "$rust" = present ]; then
      prep='apt-get update -qq && apt-get install -y -qq curl build-essential >/dev/null &&
            curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal &&
            export PATH="$HOME/.cargo/bin:$PATH"'
    fi
    ;;
  alpine)
    image=elixir:$elixir-alpine
    prep=:
    if [ "$rust" = present ]; then
      prep='apk add -q curl build-base &&
            curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal &&
            export PATH="$HOME/.cargo/bin:$PATH"'
    fi
    ;;
  nixos)
    [ "$elixir" = 1.19 ] || {
      echo "nixos runs Elixir 1.19 only" >&2
      exit 2
    }
    # Nix's store and profile, and no /lib or /lib64: a generic Linux
    # binary's loader is not there.
    image=nixos/nix:latest
    packages="nixpkgs#erlang_28 nixpkgs#elixir_1_19"
    [ "$rust" = present ] && packages="$packages nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc"
    prep="nix --extra-experimental-features 'nix-command flakes' profile install $packages &&
          export PATH=/root/.nix-profile/bin:\$PATH"
    ;;
  *)
    echo "unknown system: $system" >&2
    exit 2
    ;;
esac

exec docker run --rm \
  -v "$src:/src:ro" \
  -e RUST="$rust" \
  -e ARGUS_VERSION="${ARGUS_VERSION:-}" \
  "$image" sh -c "$prep && sh /src/test/deploy/check.sh"
