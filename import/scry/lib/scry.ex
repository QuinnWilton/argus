defmodule Scry do
  @moduledoc """
  Analysis-only Mix compiler for BEAM projects: incremental argus analyses
  via roux, reported as rich compiler diagnostics.

  Scry runs after the Elixir compiler, reads the `.beam` files it produced,
  and runs argus's Datalog analyses over them incrementally — results are
  memoized in a roux database persisted across `mix compile` runs. Findings
  are reported as `Mix.Task.Compiler.Diagnostic` structs and rendered as
  pentiment frames.

  See `Mix.Tasks.Compile.Scry` for the compiler and `Mix.Tasks.Scry` for
  the standalone task.
  """
end
