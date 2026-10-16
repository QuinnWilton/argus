#!/bin/sh
# Deploys argus the ways a user does, on the system this runs on, and checks
# each works: a Mix project with the :argus compiler (cold, then warm),
# `mix argus --all`, a prod build without argus, `mix argus.flowlog status`,
# the escript over the project's beams, `rebar3 argus` over an Erlang
# project with the rebar3_argus plugin, and offline with nothing downloaded
# (which must say why it cannot run, not crash).
#
#   ARGUS_SRC_IN   the argus checkout, read-only (default /src)
#   ARGUS_VERSION  test this release from Hex instead of the checkout
#   RUST           none (default) or present: whether this system has Rust
#   WORK           a writable directory (default /work)
#
# POSIX sh, and only grep beside Elixir: the NixOS image has no sed or awk.
set -u

src_in=${ARGUS_SRC_IN:-/src}
work=${WORK:-/work}
rust=${RUST:-none}
failed=0

pass() { echo "ok: $1"; }
fail() {
  echo "FAIL: $1"
  failed=1
}
findings() { grep -cE '^(warning|info|error)\[argus\.' "$1"; }

export LANG=C.UTF-8 ELIXIR_ERL_OPTIONS=+fnu MIX_ENV=dev

echo "== $(uname -sm), $(elixir --version 2>/dev/null | grep Elixir), Rust: $rust"

case $rust in
  none)
    if command -v cargo >/dev/null 2>&1 && [ -z "${ARGUS_CARGO:-}" ]; then
      echo "RUST=none, but cargo is on PATH"
      exit 2
    fi
    ;;
  present)
    command -v cargo >/dev/null 2>&1 || {
      echo "RUST=present, but no cargo"
      exit 2
    }
    ;;
esac

mkdir -p "$work"
cp -R "$src_in/test/deploy/demo" "$work/demo"

if [ -n "${ARGUS_VERSION:-}" ]; then
  unset ARGUS_SRC
else
  # The checkout less its builds, fetched deps and other worktrees.
  mkdir -p "$work/argus"
  for entry in "$src_in"/* "$src_in"/.formatter.exs; do
    case ${entry##*/} in
      _build | deps | tmp | cover | doc | argus) ;;
      *) cp -R "$entry" "$work/argus/" ;;
    esac
  done
  export ARGUS_SRC="$work/argus"
fi

mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null || exit 2
cd "$work/demo" || exit 2
mix deps.get >"$work/deps.log" 2>&1 || {
  cat "$work/deps.log"
  exit 2
}
mix deps.compile >"$work/deps-compile.log" 2>&1 || {
  cat "$work/deps-compile.log"
  exit 2
}

# Without Rust, argus runs on the prebuilt engines its release names, which
# fit only the native sources they were built from: a checkout that changed
# them since has none until its release builds them.
if [ "$rust" = none ]; then
  fits=$(mix run --no-start --no-compile -e '
    path = Path.join(:code.priv_dir(:argus_beam), "flowlog/prebuilt.json")
    native = path |> File.read!() |> JSON.decode!() |> Map.fetch!("native")
    IO.puts(native == Argus.FlowLog.Native.digest())' 2>/dev/null | grep -E '^(true|false)$')

  if [ "$fits" != true ]; then
    echo "skipped: this checkout's native sources have no prebuilt engines yet (fits=$fits)"
    exit 0
  fi
fi

mix compile >"$work/cold.log" 2>&1
code=$?
count=$(findings "$work/cold.log")
if [ $code -eq 0 ] && [ "$count" -gt 0 ]; then
  pass "cold compile with the :argus compiler ($count findings)"
else
  fail "cold compile with the :argus compiler (exit $code, $count findings)"
  tail -40 "$work/cold.log"
fi

mix compile >"$work/warm.log" 2>&1
code=$?
if [ $code -eq 0 ] && ! grep -q 'argus: ' "$work/warm.log"; then
  pass "warm compile"
else
  fail "warm compile (exit $code)"
  tail -20 "$work/warm.log"
fi

mix argus --all >"$work/all.log" 2>&1
code=$?
if [ $code -eq 0 ]; then
  pass "mix argus --all ($(findings "$work/all.log") findings)"
else
  fail "mix argus --all (exit $code)"
  tail -30 "$work/all.log"
fi

MIX_ENV=prod mix compile >"$work/prod.log" 2>&1
code=$?
if [ $code -eq 0 ]; then
  pass "prod build without argus"
else
  fail "prod build without argus (exit $code)"
  tail -20 "$work/prod.log"
fi

if mix argus.flowlog status >"$work/status.log" 2>&1; then
  pass "mix argus.flowlog status"
  grep -E '^(rust|prebuilt|toolchain):' "$work/status.log"
else
  fail "mix argus.flowlog status"
  cat "$work/status.log"
fi

# The escript: built from the checkout, or the release's from Hex.
if [ -n "${ARGUS_VERSION:-}" ]; then
  mix escript.install hex argus_beam "$ARGUS_VERSION" --force >"$work/escript.log" 2>&1
  escript="$HOME/.mix/escripts/argus"
else
  (cd "$ARGUS_SRC" && mix deps.get >/dev/null 2>&1 && MIX_ENV=prod mix escript.build) \
    >"$work/escript.log" 2>&1
  escript="$ARGUS_SRC/argus"
fi

if [ -x "$escript" ]; then
  "$escript" --project beams --ebin "$work/demo/_build/dev/lib/depot/ebin" \
    --state-dir "$work/escript-state" --analyses coupling,mailbox >"$work/run.log" 2>&1
  code=$?
  count=$(findings "$work/run.log")

  if [ $code -eq 0 ] && [ "$count" -gt 0 ]; then
    pass "escript over the beams ($count findings)"
  else
    fail "escript over the beams (exit $code, $count findings)"
    tail -30 "$work/run.log"
  fi

  if [ "$rust" = none ]; then
    ARGUS_OFFLINE=1 ARGUS_CARGO=/nonexistent ARGUS_FLOWLOG_DIR="$work/no-engines" \
      "$escript" --project beams --ebin "$work/demo/_build/dev/lib/depot/ebin" \
      --state-dir "$work/offline-state" >"$work/offline.log" 2>&1
    code=$?

    if [ $code -eq 3 ] && grep -q 'offline' "$work/offline.log"; then
      pass "offline with nothing downloaded says why (exit 3)"
    else
      fail "offline with nothing downloaded (exit $code)"
      cat "$work/offline.log"
    fi
  fi
else
  fail "escript build"
  tail -30 "$work/escript.log"
fi

# rebar3: the rebar3_argus plugin from Hex over an Erlang project, with the
# escript above (ARGUS_ESCRIPT), or for a release the one the plugin
# downloads by version. rebar3 is the one Mix installed.
rebar3=
for candidate in "$HOME"/.mix/elixir/*/rebar3; do
  [ -f "$candidate" ] && rebar3=$candidate
done

cp -R "$src_in/test/deploy/rebar3_demo" "$work/rebar3_demo"
if [ -n "${ARGUS_VERSION:-}" ]; then
  echo "{argus_plugin, [{version, \"$ARGUS_VERSION\"}]}." >>"$work/rebar3_demo/rebar.config"
  plugin_escript=
else
  plugin_escript=$escript
fi

(cd "$work/rebar3_demo" && ARGUS_ESCRIPT="$plugin_escript" escript "$rebar3" argus) \
  >"$work/rebar3.log" 2>&1
code=$?
count=$(findings "$work/rebar3.log")

if [ $code -eq 0 ] && [ "$count" -gt 0 ]; then
  pass "rebar3 argus with the plugin ($count findings)"
else
  fail "rebar3 argus with the plugin (exit $code, $count findings, rebar3 ${rebar3:-not found})"
  tail -30 "$work/rebar3.log"
fi

# The plugin offline, with no escript downloaded: an error that says why.
if [ -n "${ARGUS_VERSION:-}" ]; then
  (cd "$work/rebar3_demo" && XDG_CACHE_HOME="$work/empty-cache" escript "$rebar3" argus --offline) \
    >"$work/rebar3-offline.log" 2>&1
  code=$?

  if [ $code -ne 0 ] && grep -q 'not downloaded yet, and argus is offline' "$work/rebar3-offline.log"; then
    pass "rebar3 argus offline with no escript says why (exit $code)"
  else
    fail "rebar3 argus offline with no escript (exit $code)"
    cat "$work/rebar3-offline.log"
  fi
fi

exit $failed
