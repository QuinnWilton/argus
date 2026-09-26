# Commit policy; run with `mix presubmit`, installed as hooks by `mix presubmit.install`.
[
  {Presubmit.Rules.Elixir, except: [:removals_deprecated, :pure_move]},
  Presubmit.Rules.Hygiene,
  Presubmit.Rules.Mix,
  # The changelog is written at release time, under the version heading.
  {Presubmit.Rules.Changelog, warn: [:api_changes_logged]},
  {Presubmit.Rules.Message, subject: ~r/^\[[a-z_-]+\] [a-z0-9]/, max_subject_length: 72}
]
