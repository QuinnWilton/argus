defmodule Argus.Extractors.ErrorHandling.ErrorBranchTest do
  use ExUnit.Case, async: true

  alias Argus.Cfg
  alias Argus.Extractor.Helpers
  alias Argus.Extractors.ErrorHandling.ErrorBranch
  alias Argus.Pipeline.Disassemble

  # The local calls each function makes only on an error branch, as
  # {function, callee}.
  defp on_error(source) do
    [{_mod, bin}] = Code.compile_string(source)
    {:ok, data} = Disassemble.disassemble_path(bin)

    for {:function, name, arity, _entry, instrs} <- data.functions,
        table = List.to_tuple(instrs),
        idx <- ErrorBranch.calls(Cfg.build_for(data, name, arity), table),
        {:ok, _m, callee, callee_arity} <- [Helpers.match_local_call(elem(table, idx))],
        uniq: true,
        do: {"#{name}/#{arity}", "#{callee}/#{callee_arity}"}
  end

  test "a call under {:error, _} or a with's else for it is on the error branch; one a " <>
         "success path also reaches is not" do
    rows =
      on_error("""
      defmodule Argus.ErrorBranchTest.Cases do
        def by_case(x) do
          case fetch(x) do
            {:ok, v} -> keep(v)
            {:error, _} -> retry(x)
          end
        end

        def by_with(x) do
          with {:ok, v} <- fetch(x) do
            keep(v)
          else
            {:error, _} -> retry(x)
          end
        end

        def by_atom(x) do
          if fetch(x) == :error, do: retry(x), else: keep(x)
        end

        def after_either(x) do
          _ =
            case fetch(x) do
              {:ok, v} -> v
              {:error, _} -> nil
            end

          keep(x)
        end

        def any_failure(x) do
          case fetch(x) do
            {:ok, v} -> keep(v)
            _other -> retry(x)
          end
        end

        defp fetch(x), do: Application.get_env(:probe, x)
        defp keep(v), do: {:kept, v}
        defp retry(x), do: send(self(), {:retry, x})
      end
      """)

    # A with's else clauses are a function of their own.
    assert Enum.sort(rows) == [
             {"-by_with/1-fun-0-/2", "retry/1"},
             {"by_atom/1", "retry/1"},
             {"by_case/1", "retry/1"}
           ]
  end
end
