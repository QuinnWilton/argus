# Commit policy; run with `mix presubmit`, installed as hooks by `mix presubmit.install`.
[
  {Presubmit.Rules.Elixir, except: [:removals_deprecated, :pure_move]},
  Presubmit.Rules.Hygiene,
  Presubmit.Rules.Mix,
  # Changelog entries land in the release commit here, not the feature commit.
  {Presubmit.Rules.Changelog, warn: [:api_changes_logged]},
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
   ]}
]
