defmodule Argus.Souffle.CLI do
  @moduledoc """
  Souffle execution via shell-out to the `souffle` command-line tool.

  Invokes `souffle -F <facts_dir> -D <output_dir> <rules.dl>` and parses
  the tab-separated output files back into lists of string rows.
  """

  @behaviour Argus.Souffle

  @impl true
  def run(facts_dir, rules_path, opts \\ []) do
    souffle_bin = Keyword.get(opts, :souffle_bin, find_souffle())

    case souffle_bin do
      nil ->
        {:error, :souffle_not_found}

      bin ->
        output_dir =
          Keyword.get_lazy(opts, :output_dir, fn ->
            tmp = System.tmp_dir!()
            dir = Path.join(tmp, "argus_souffle_#{System.unique_integer([:positive])}")
            File.mkdir_p!(dir)
            dir
          end)

        run_souffle(bin, facts_dir, rules_path, output_dir)
    end
  end

  @doc """
  Returns true if the `souffle` binary is available on the system PATH.
  """
  @spec available?() :: boolean()
  def available? do
    find_souffle() != nil
  end

  defp find_souffle do
    case System.find_executable("souffle") do
      nil -> nil
      path -> path
    end
  end

  defp run_souffle(bin, facts_dir, rules_path, output_dir) do
    args = [
      "-F",
      facts_dir,
      "-D",
      output_dir,
      rules_path
    ]

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {_output, 0} ->
        parse_output(output_dir)

      {output, exit_code} ->
        {:error, {:souffle_error, exit_code, output}}
    end
  end

  defp parse_output(output_dir) do
    results =
      output_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".csv"))
      |> Map.new(fn filename ->
        relation = String.trim_trailing(filename, ".csv")
        path = Path.join(output_dir, filename)

        rows =
          path
          |> File.read!()
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(&String.split(&1, "\t"))

        {relation, rows}
      end)

    {:ok, results}
  end
end
