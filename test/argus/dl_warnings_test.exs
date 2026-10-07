defmodule Argus.DlWarningsTest do
  @moduledoc """
  Every shipped program compiles through FlowLog's front end and planner,
  and is one argus can host (`Argus.FlowLog.Program.inspect/2`): every
  input `mutable`, every input and output column a symbol or a number.

  FlowLog reports the relations a program never reaches as it prunes them;
  argus's programs include the whole schema and rely on that pruning, so
  it is no warning here.
  """
  use ExUnit.Case, async: true

  @moduletag :flowlog

  @tag timeout: 300_000
  test "shipped analyses and stages compile, and argus can host them" do
    dl = Argus.Dl.root()

    Argus.FlowLog.builtin_programs()
    |> Task.async_stream(
      fn program -> {Path.relative_to(program, dl), Argus.FlowLog.manifest(program)} end,
      max_concurrency: 4,
      timeout: 300_000
    )
    |> Enum.each(fn {:ok, {program, result}} ->
      assert {:ok, %{inputs: [_ | _], outputs: [_ | _]}} = result,
             "#{program} does not compile:\n#{inspect(result)}"
    end)
  end
end
