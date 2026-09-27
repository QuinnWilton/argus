defmodule Argus.Test.Escript do
  @moduledoc """
  The `argus` escript built from this checkout, once per test run
  (`mix escript.build` in `:prod`, a separate OS process), for the tests
  that run it as a user does (`@tag :escript`).
  """

  @repo Path.expand("../..", __DIR__)

  @doc """
  The path of a copy of the escript outside the repository, built on
  the first call of the run.
  """
  @spec build!() :: Path.t()
  def build! do
    :global.trans({{__MODULE__, :build}, self()}, fn ->
      case :persistent_term.get(__MODULE__, nil) do
        nil ->
          path = build()
          :persistent_term.put(__MODULE__, path)
          path

        path ->
          path
      end
    end)
  end

  defp build do
    {output, status} =
      System.cmd("mix", ["escript.build"],
        cd: @repo,
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("mix escript.build failed:\n" <> output)

    dir = Path.join(System.tmp_dir!(), "argus_escript_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    escript = Path.join(dir, "argus")
    File.cp!(Path.join(@repo, "argus"), escript)
    escript
  end
end
