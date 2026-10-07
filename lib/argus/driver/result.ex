defmodule Argus.Driver.Result do
  @moduledoc """
  What one run of the driver found, for a frontend to render.

    * `located` — each analysis run: its findings placed in the source
      (`Argus.Located`), or why it degraded and reported nothing (the
      engine failed or timed out, a stage it reads failed, its rules
      and argus's code are out of step). An analysis the run did not
      solve (no engines here, `engine: :warn`) is not there.
    * `notices` — what a reader of the findings should know about the
      run that is not a finding (`t:notice/0`). An analysis that
      degraded is not among them: `located` says so.
    * `changed?` — whether the run found anything moved since the last
      (a Mix compiler's `:ok` against `:noop`).

  ## Notices

    * `:engine_unavailable` — the FlowLog engines cannot be built or run
      on this machine (`Argus.FlowLog.Toolchain`): nothing was solved.
    * `{:extraction_error, error}` — a step of extraction failed on a
      module (`step: "module"` when the module could not be extracted at
      all): the analyses ran without those facts, and a finding that
      needed them may be missing.
    * `{:duplicate, duplicate}` — a module more than one scanned ebin
      defines: which beam is analyzed, and which are passed over.
    * `{:points_to_bounded, leaves}` — the process points-to stage
      outgrew its budget and ran bounded, resolving `leaves` coarsely
      (a sound superset of their exact rows).
  """

  @enforce_keys [:located, :notices, :changed?]
  defstruct [:located, :notices, :changed?]

  @typedoc "A module extraction could not fully read."
  @type extraction_error :: %{
          module: module() | nil,
          name: String.t(),
          step: String.t(),
          reason: String.t()
        }

  @typedoc "A module more than one scanned ebin defines."
  @type duplicate :: %{module: module(), used: String.t(), shadowed: [String.t()]}

  @type notice ::
          :engine_unavailable
          | {:extraction_error, extraction_error()}
          | {:duplicate, duplicate()}
          | {:points_to_bounded, [String.t()]}

  @type t :: %__MODULE__{
          located: %{optional(atom()) => {:ok, [Argus.Located.t()]} | {:error, term()}},
          notices: [notice()],
          changed?: boolean()
        }

  @doc "The analyses that degraded, with why."
  @spec degraded(t()) :: [%{analysis: atom(), reason: term()}]
  def degraded(%__MODULE__{located: located}) do
    for {analysis, {:error, reason}} <- Enum.sort(located),
        do: %{analysis: analysis, reason: reason}
  end

  @doc "Whether the run could not solve: the engines are unavailable here."
  @spec engine_unavailable?(t()) :: boolean()
  def engine_unavailable?(%__MODULE__{notices: notices}), do: :engine_unavailable in notices
end
