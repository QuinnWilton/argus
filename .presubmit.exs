# Commit policy; run with `mix presubmit`, installed as hooks by `mix presubmit.install`.
[
  Presubmit.Rules.Elixir,
  Presubmit.Rules.Hygiene,
  Presubmit.Rules.Mix,
  # The changelog is written at release time, under the version heading.
  {Presubmit.Rules.Changelog, warn: [:api_changes_logged]},
  {Presubmit.Rules.ExUnit, only: [:behaviour_changes_tested]},
  {Presubmit.Rules.Message,
   subject: ~r/^\[[a-z_-]+\] [a-z0-9]/,
   max_subject_length: 72,
   trailers: [
     {fn commit ->
        Enum.any?(
          Presubmit.Query.trailer(commit, "Co-Authored-By"),
          &(&1 =~ ~r/anthropic\.com/)
        )
      end, "Claude-Session", ~r{^https://claude\.ai/code/session_}}
   ]},
  {Presubmit.Rules.Shape, max_files: 60, max_additions: 3000}
]
