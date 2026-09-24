defmodule Argus.Cache.Code do
  @moduledoc """
  The code a producer's facts depend on (`Argus.Pipeline`'s producers),
  as a digest: what `Argus.Cache.Facts` keys each producer's shard on.

  A producer runs the code a remote call reaches from its roots: the
  base from `Argus.Pipeline`, an extractor from itself and from
  `Argus.Pipeline` (every extractor reads what the base computes). The
  walk reads each module's import table and follows it through this
  project and its dependencies — beam_spy's disassembly, ctf's
  literals — and stops at OTP and Elixir, whose versions a key carries
  instead, and at consolidated protocols, the build's dispatch tables.
  The one dynamic call on the way, `extractor.extract/1`, is why each
  extractor is a root of its own; `Argus.Cache.CodeTest` runs every
  producer with call counting on and checks that nothing it executes
  lies outside its closure.

  So an edit to one extractor moves its own digest and no other; an
  edit to a module the base reaches (`Argus.Instr`, the extractor
  helpers) moves every producer's. What only solves or reports on the
  facts — the Souffle runner, the stores, the analyses' prose and
  rules — is reached by no producer, and moves none.

  Each module is hashed by `Argus.BeamDigest` (without debug info): a
  build in another worktree of the same code digests the same. The
  digests are taken once per VM, from the beams on disk: a VM that
  reloads changed code mid-run keys on what it started with.
  """

  @typedoc "`:base` or an extractor module (`Argus.Pipeline.producer/0`)."
  @type producer :: Argus.Pipeline.producer()

  @doc """
  The modules a producer's rows depend on, sorted, each with the beam it
  runs from — or `:absent`, a module called on the way that is not on
  the code path (an optional dependency), whose arrival would change
  what the call does. An error names a module that has no beam on disk
  to digest (compiled in memory, or cover-compiled): no key can name its
  code.
  """
  @spec closure(producer()) ::
          {:ok, [{module(), Path.t() | :absent}]} | {:error, {:no_beam, module()}}
  def closure(producer) do
    memo({:closure, producer}, fn ->
      with {:ok, modules} <- producer |> roots() |> reachable(%{}) do
        {:ok, Enum.sort(modules)}
      end
    end)
  end

  @doc """
  A digest of `closure/1`'s code: each module by name and
  `Argus.BeamDigest`, or as absent. Once per VM for each producer.
  """
  @spec digest(producer()) :: {:ok, String.t()} | {:error, term()}
  def digest(producer) do
    memo({:digest, producer}, fn ->
      with {:ok, modules} <- closure(producer),
           {:ok, parts} <- module_parts(modules) do
        {:ok, Argus.Cache.key(parts)}
      end
    end)
  end

  defp module_parts(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn {mod, beam}, {:ok, acc} ->
      case module_part(mod, beam) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp module_part(mod, :absent), do: {:ok, "absent " <> Atom.to_string(mod)}

  defp module_part(mod, beam) do
    case memo({:module, mod}, fn -> Argus.BeamDigest.digest(beam) end) do
      {:ok, code} -> {:ok, Atom.to_string(mod) <> " " <> code}
      {:error, reason} -> {:error, {:beam_unreadable, mod, reason}}
    end
  end

  @doc """
  Whether a producer can read specs from the code path
  (`Argus.Specs.installed/2`): its rows then depend on the environment
  as well as on the beams.
  """
  @spec reads_installed?(producer()) :: boolean()
  def reads_installed?(producer) do
    case closure(producer) do
      {:ok, modules} -> List.keymember?(modules, Argus.Specs, 0)
      {:error, _} -> true
    end
  end

  defp roots(:base), do: [Argus.Pipeline]
  defp roots(extractor) when is_atom(extractor), do: [extractor, Argus.Pipeline]

  defp reachable([], seen), do: {:ok, Map.to_list(seen)}

  defp reachable([mod | rest], seen) do
    if Map.has_key?(seen, mod) do
      reachable(rest, seen)
    else
      case where(mod) do
        :runtime ->
          reachable(rest, seen)

        :absent ->
          reachable(rest, Map.put(seen, mod, :absent))

        :no_beam ->
          {:error, {:no_beam, mod}}

        {:beam, beam} ->
          {:ok, {^mod, [imports: imports]}} =
            :beam_lib.chunks(String.to_charlist(beam), [:imports])

          called = for {callee, _fun, _arity} <- imports, uniq: true, do: callee
          reachable(called ++ rest, Map.put(seen, mod, beam))
      end
    end
  end

  # A module of this project or a dependency is digested, from its beam;
  # OTP's and Elixir's own are covered by their versions, and a
  # consolidated protocol is the build's dispatch table, not code that
  # shapes a fact.
  defp where(mod) do
    case :code.which(mod) do
      :non_existing ->
        :absent

      :preloaded ->
        :runtime

      path when is_list(path) and path != [] ->
        path = List.to_string(path)

        cond do
          String.starts_with?(path, List.to_string(:code.root_dir())) -> :runtime
          String.starts_with?(path, elixir_root()) -> :runtime
          "consolidated" in Path.split(path) -> :runtime
          true -> {:beam, path}
        end

      _in_memory_or_cover_compiled ->
        :no_beam
    end
  end

  defp elixir_root, do: :elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()

  defp memo(key, compute) do
    key = {__MODULE__, key}

    case :persistent_term.get(key, nil) do
      nil ->
        value = compute.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end
end
