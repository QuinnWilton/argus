defmodule Argus.Schema.Pin do
  @moduledoc """
  Compile-time assertion that argus's fact schema is one this consumer was
  written against.

  Argus emits facts as positional rows, so a schema change — a new relation,
  a renamed or reordered field, a field whose meaning shifts — can silently
  mis-decode in a consumer rather than fail. Argus is a path dependency in
  this workspace, so consumers recompile whenever it does, which makes
  compile time the honest place to catch that. Calling `Argus.Schema.version/0`
  from a module body records a compile-time dependency on `Argus.Schema`, so
  the check re-runs on every schema edit without any manifest bookkeeping.

      defmodule Gloss.Adapters do
        # v3 revisit: line_info became per-instruction (sticky from the last
        # marker) — a strict superset of the v2 marker rows, so the passes
        # read unchanged.
        # v8: positional columns split out of function_def and call_arg.
        # Gloss reads neither relation, so the passes need no revisiting.
        use Argus.Schema.Pin, versions: 3..8, review: "Gloss.Entries and Gloss.Adapters"
      end

  Keep the per-version reasoning as comments next to the `use`. Recording
  *why* a version is compatible is the part that makes the next bump cheap,
  and it is necessarily specific to what the consumer reads — a Layer-2
  change is invisible to a Layer-1 consumer, and only the consumer knows
  that.

  ## Choosing `versions`

  Accepts a range or an explicit list. Prefer a range: it states "everything
  from the oldest version I still decode correctly through the newest I have
  reviewed", which is what consumers actually mean. Use a list only when
  support genuinely has a hole, which should be rare enough to want a comment
  explaining it.

  A single version (`versions: 8..8`) is the strictest choice and is right
  for a consumer that reads deeply enough across both layers that no bump is
  ever obviously safe.

  ## Options

    * `:versions` — required. A range or list of accepted schema versions.
    * `:review` — optional. What the next person should re-read before
      widening the pin, named in the error message. Defaults to the module
      the pin is declared in.
    * `:as` — optional. Name for the generated accessor holding the accepted
      versions. Defaults to `__argus_schema_versions__`.
  """

  @doc """
  Declares the argus fact-schema versions this module is written against.

  Raises `CompileError` at the `use` site when `Argus.Schema.version/0` falls
  outside the declared set.
  """
  defmacro __using__(opts) do
    {versions, review, accessor} = validate!(opts, __CALLER__)

    consumer =
      __CALLER__.module
      |> Module.split()
      |> hd()

    current = Argus.Schema.version()

    unless current in versions do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description:
          "#{consumer} is written against argus fact-schema " <>
            "#{describe(versions)}, but argus declares version #{current}. " <>
            "Review #{review} against the argus CHANGELOG entry for v#{current}, " <>
            "then widen this pin and record why the new version is compatible."
    end

    quote do
      @doc false
      def unquote(accessor)(), do: unquote(versions)
    end
  end

  # Options are evaluated rather than pattern-matched so that `3..8` and
  # `[3, 4, 5]` are both accepted. They are literals at every call site, so
  # evaluating in the caller's context is safe and gives a useful error for
  # anything that is not.
  defp validate!(opts, caller) do
    opts = eval!(opts, caller, ":versions must be given as a literal, e.g. `versions: 3..8`")

    versions =
      case Keyword.fetch(opts, :versions) do
        {:ok, %Range{} = range} -> Enum.to_list(range)
        {:ok, list} when is_list(list) -> list
        {:ok, other} -> bad_versions!(caller, other)
        :error -> raise_at(caller, "Argus.Schema.Pin requires a :versions option")
      end

    unless versions != [] and Enum.all?(versions, &(is_integer(&1) and &1 > 0)) do
      bad_versions!(caller, versions)
    end

    review = Keyword.get(opts, :review, inspect(caller.module))
    accessor = Keyword.get(opts, :as, :__argus_schema_versions__)

    {Enum.sort(versions), review, accessor}
  end

  defp eval!(opts, caller, message) do
    {value, _binding} = Code.eval_quoted(opts, [], caller)
    value
  rescue
    _ -> raise_at(caller, message)
  end

  @spec bad_versions!(Macro.Env.t(), term()) :: no_return()
  defp bad_versions!(caller, got) do
    raise_at(
      caller,
      ":versions must be a non-empty range or list of positive integers, got: #{inspect(got)}"
    )
  end

  @spec raise_at(Macro.Env.t(), String.t()) :: no_return()
  defp raise_at(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  # A contiguous run reads as a range; anything else is listed, because a gap
  # is the interesting part and collapsing it would hide it.
  defp describe([single]), do: "version #{single}"

  defp describe(versions) do
    first = hd(versions)
    last = List.last(versions)

    if last - first + 1 == length(versions) do
      "versions #{first}-#{last}"
    else
      "versions #{Enum.join(versions, ", ")}"
    end
  end
end
