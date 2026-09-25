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

  ## The schema

  `Argus.Schema` and its concern modules (`Argus.Schema.*`) are in
  every producer's closure, and their beams hold every relation as
  literals: keyed as code, an edit to any relation moves every key.
  With `schema: :recorded` they are left out — walked through, so what
  they call is still keyed — for a caller that keys on the entries a
  producer read of them instead (`Argus.Cache.Reads`). That is sound
  because they are data: every
  export of theirs records the entry it returns
  (`Argus.SchemaReadsTest`). By default (`schema: :included`) they are
  keyed as any other code, for a caller that records no reads.
  """

  @typedoc "`:base` or an extractor module (`Argus.Pipeline.producer/0`)."
  @type producer :: Argus.Pipeline.producer()

  @typedoc """
  `schema: :recorded` leaves the schema's modules out of a closure (see
  "The schema"); the default is `:included`.
  """
  @type option :: {:schema, :included | :recorded}

  @doc """
  The modules a producer's rows depend on, sorted, each with the beam it
  runs from — or `:absent`, a module called on the way that is not on
  the code path (an optional dependency), whose arrival would change
  what the call does. An error names a module that has no beam on disk
  to digest (compiled in memory, or cover-compiled): no key can name its
  code.
  """
  @spec closure(producer(), [option()]) ::
          {:ok, [{module(), Path.t() | :absent}]} | {:error, {:no_beam, module()}}
  def closure(producer, opts \\ []) do
    schema = schema_option(opts)
    memo({:closure, producer, schema}, fn -> walk(producer, schema) end)
  end

  defp walk(:base, schema) do
    with {:ok, modules} <- reachable([Argus.Pipeline], %{}, schema) do
      {:ok, Enum.sort(modules)}
    end
  end

  # An extractor's is the base's and what the extractor reaches besides:
  # the walk from the extractor stops where the base's closure, read
  # once, already goes.
  defp walk(extractor, schema) when is_atom(extractor) do
    with {:ok, base} <- closure(:base, schema: schema),
         {:ok, modules} <- reachable([extractor], Map.new(base), schema) do
      {:ok, Enum.sort(modules)}
    end
  end

  defp schema_option(opts) do
    case Keyword.get(opts, :schema, :included) do
      schema when schema in [:included, :recorded] ->
        schema

      other ->
        raise ArgumentError, ":schema must be :included or :recorded, got: #{inspect(other)}"
    end
  end

  @doc """
  A digest of `closure/2`'s code: each module by name and
  `Argus.BeamDigest`, or as absent. Once per VM for each producer.
  """
  @spec digest(producer(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def digest(producer, opts \\ []) do
    schema = schema_option(opts)

    memo({:digest, producer, schema}, fn ->
      with {:ok, modules} <- closure(producer, schema: schema),
           {:ok, parts} <- module_parts(modules) do
        {:ok, Argus.Cache.key(parts)}
      end
    end)
  end

  @doc """
  Whether `module` is one of the schema's (`Argus.Schema` or a module
  under it), which `schema: :recorded` leaves out of a closure.
  """
  @spec schema_module?(module()) :: boolean()
  def schema_module?(Argus.Schema), do: true

  def schema_module?(module) when is_atom(module),
    do: String.starts_with?(Atom.to_string(module), "Elixir.Argus.Schema.")

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

  # `seen` holds each module met: its beam, `:absent`, or `:walked` — a
  # schema module under `schema: :recorded`, whose calls are followed
  # but which is itself left out.
  defp reachable([], seen, _schema),
    do: {:ok, for({mod, found} <- seen, found != :walked, do: {mod, found})}

  defp reachable([mod | rest], seen, schema) do
    if Map.has_key?(seen, mod) do
      reachable(rest, seen, schema)
    else
      case where(mod) do
        :runtime ->
          reachable(rest, seen, schema)

        :absent ->
          reachable(rest, Map.put(seen, mod, :absent), schema)

        :no_beam ->
          {:error, {:no_beam, mod}}

        {:beam, beam} ->
          {:ok, {^mod, [imports: imports]}} =
            :beam_lib.chunks(String.to_charlist(beam), [:imports])

          called = for {callee, _fun, _arity} <- imports, uniq: true, do: callee
          found = if schema == :recorded and schema_module?(mod), do: :walked, else: beam
          reachable(called ++ rest, Map.put(seen, mod, found), schema)
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
