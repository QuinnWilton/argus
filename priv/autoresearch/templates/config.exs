# Argus autoresearch configuration.
#
# This file is read by `mix argus.autoresearch` subcommands at the
# start of each run. It's committed to the repo so autoresearch runs
# are reproducible across contributors.
#
# If a project listed in a tier doesn't exist at runtime, the loop
# logs it as missing and continues — no hard failures on absence.

%{
  # Root directory containing per-project subdirectories. Relative
  # paths are expanded against the user's home directory.
  corpus_root: "~/dev/beam_box/sample_projects",

  # Named corpus tiers. Each value is either a list of project
  # directory names (relative to corpus_root) or the atom :all,
  # meaning "every project under corpus_root that has mix.exs or
  # rebar.config".
  tiers: %{
    "fast" => ~w(poolboy phoenix_pubsub plug jason bandit),
    "medium" => ~w(poolboy phoenix_pubsub plug jason bandit oban broadway ecto),
    "full" => :all
  },

  # Tier used when no --tier flag is passed. The fast tier should
  # complete in under 2 minutes so iteration stays tight.
  default_tier: "fast",

  # Project used for the canary correctness cross-check. After every
  # accepted improvement, the default correctness analyses are re-run
  # against this project and finding counts are compared to a
  # committed fixture. Drift blocks the next accept.
  canary_project: "poolboy",

  # Commands that must pass before an attempt can be accepted.
  # Each entry is [executable, [args]]. Commands run in sequence;
  # the first failure aborts the barrier.
  checks_barrier: [
    ["mix", ["format", "--check-formatted"]],
    ["mix", ["compile", "--warnings-as-errors"]],
    ["mix", ["test"]],
    ["mix", ["dialyzer"]]
  ],

  # Parallelism for the per-project measurement fanout. Each project
  # runs in its own OS subprocess, so this bounds memory and CPU.
  measure_concurrency: 4,

  # Per-project timeout in seconds. Projects exceeding this are
  # marked failed but don't abort the whole measurement.
  measure_timeout_s: 300
}
