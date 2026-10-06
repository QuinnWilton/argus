defmodule Argus.Test.CallCount do
  @moduledoc """
  The code a check counts calls into (`code/0`), for a counting session
  over it (`Roux.Code.Verify.counting/2`):

      Roux.Code.Verify.counting(
        fn session -> Roux.Code.Verify.calls(session, run) end,
        modules: Argus.Test.CallCount.code()
      )

  Counts are VM-wide: every process's calls count, so count in a VM
  doing nothing else (`Argus.Test.Peer.start!(code_path: :this)`).
  """

  @doc "The modules counted: argus's code and its libraries', not its tests'."
  @spec code() :: [module()]
  def code do
    for app <- [:argus_beam, :beam_spy, :ctf],
        mod <- Application.spec(app, :modules) || [],
        not String.starts_with?(Atom.to_string(mod), ["Elixir.Argus.Test.", "Elixir.Inspect."]),
        do: mod
  end
end
