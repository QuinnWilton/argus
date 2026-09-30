defmodule Argus.Specs do
  @moduledoc """
  What a function's `@spec` claims it returns, reduced to the few shapes
  a rule can use.

  A spec is an unverified claim: nothing checks that `ets:delete/2`
  returns `true` except the author, and a spec can be wrong. The facts
  built from specs may therefore only *suppress* a finding (a callee
  whose spec names no failure value is not a result anyone must check)
  or *confirm* one another rule already derived; no rule reports a
  finding on a spec alone.

  ## Shapes

  - `:can_fail` — the return type names a value that says the call did
    not do its job: `{:error, _}`, `:error`, `nil`, `false`, `:undefined`
    or `{:EXIT, _}`. `boolean()` is `true | false` and so can fail: the
    `false` of `:ets.insert_new/2` is the insert that did not happen.
    Only literal values count; `atom()` is not taken to include `:error`.
  - `:total` — the return type is known and names none of those values:
    `true`, `:ok`, `table()`, `reference()`. `term()` and `any()` are not
    known, and a union containing either is not total.
  - `:constant` — the return type is one literal atom (`:ok`, `true`),
    so the result tells a caller nothing: also `:total`.
  - `:no_return` — every clause returns `no_return()` or `none()`.
  - `:returns_pid` — a clause may return a pid, bare or as `{:ok, pid}`.

  A function may have several shapes (`GenServer.on_start/0` both
  returns a pid and can fail), or none: no spec, or a spec whose return
  is `term()`, is *unknown*, never "cannot fail".

  User and remote types are resolved to a bounded depth (four levels);
  what lies below is unknown. `:mnesia` and `Ecto.Repo` ship no spec
  chunk: every function of theirs is unknown.

  ## Where specs come from

  `of_beam/1` reads an analyzed module's own beam (its debug info);
  `installed/1` looks a module up on the code path, and memoizes the
  answer per module for the life of the VM, keyed by the file it was read
  from, so a recompiled dependency is read again; `installed/2` and
  `of_beam/2` answer from a table the caller keeps for one run instead,
  which asks the code path about each module once — or, when the table
  carries a source (`Argus.Specs.Source`, `Argus.Pipeline`'s
  `specs_source:`), the project's own ebins and the installed OTP, and
  never the code path. What reading one module's specs can give is
  `interface_digest/2`: the query graph keys each read on it
  (`Argus.Graph.Reads`'s `installed_specs`).
  """

  require Record

  alias Argus.Specs.Source
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @max_depth 4

  @typedoc "A normalized return shape."
  @type shape :: :can_fail | :total | :constant | :no_return | :returns_pid

  @typedoc "Each specced function's shapes; a function absent here is unknown."
  @type returns :: %{{atom(), arity()} => [shape()]}

  # The types a spec's names resolve against — the module's own, or a
  # remote module's while its type is expanded — and the run's memo.
  @typep scope :: {%{{atom(), arity()} => {list(), tuple()}}, :ets.tid() | nil}

  # One alternative of a return type, after resolution.
  @typep alt ::
           {:atom, atom()}
           | {:tuple, [[alt()]] | :any}
           | :pid
           | :any
           | :none
           | :other

  @failure_atoms [:error, nil, false, :undefined]
  @failure_tags [:error, :EXIT]

  @doc """
  The shapes of every specced function in a beam, given as its path or
  its contents. `:error` when the beam carries no debug info to read
  specs from.
  """
  @spec of_beam(Path.t() | binary(), :ets.tid() | nil) :: {:ok, returns()} | :error
  def of_beam(beam, memo \\ nil) when is_binary(beam) do
    with {:ok, binary} <- read_beam(beam),
         {:ok, {module, chunk}} <- fetch(fn -> read_chunk(binary) end) do
      of_debug_info(module, chunk, memo)
    end
  end

  @doc """
  `of_beam/2` for a debug-info chunk already read
  (`{:debug_info_v1, backend, data}`, as `:beam_lib.chunks/2` returns
  it) of `module`: what `Argus.Extractors.Specs` asks, with the chunk the
  pipeline read once for every extractor that wants it.
  """
  @spec of_debug_info(module(), tuple(), :ets.tid() | nil) :: {:ok, returns()} | :error
  def of_debug_info(module, chunk, memo \\ nil) when is_atom(module) do
    with {:ok, forms} <- fetch(fn -> typespec_forms(module, chunk) end) do
      specs = for {:attribute, _, :spec, value} <- forms, do: value
      {:ok, reduce(specs, types_of(forms), memo)}
    end
  end

  @doc """
  The shapes of `module`'s specced functions as installed on the code
  path, or `:unknown` when it is not there or carries no specs.
  Memoized per module and file.
  """
  @spec installed(module()) :: returns() | :unknown
  def installed(module) when is_atom(module), do: stamped_installed(module, nil)

  @doc """
  `installed/1`, answered once per `memo`: an ETS table (`:public`,
  `:set`) the caller owns for one extraction over one code path, which
  `Argus.Pipeline` hands every module's extractors as
  `module_data.installed_specs`. `installed/1` asks the code server where
  a module lives and stats the file every time it reads one — the
  module's own specs and every remote type they name — so that an edit
  is seen; within a run there is nothing to see. `nil` is `installed/1`.
  """
  @spec installed(module(), :ets.tid() | nil) :: returns() | :unknown
  def installed(module, nil), do: installed(module)

  def installed(module, memo) when is_atom(module),
    do: memoized(memo, {:specs, module}, fn -> stamped_installed(module, memo) end)

  defp stamped_installed(module, memo) do
    case installed_declarations(module, memo) do
      :unknown -> :unknown
      specs -> reduce(specs, installed_types(module, memo), memo)
    end
  end

  # Cache declarations, not resolved shapes: remote types have their own
  # stamps and must be read again, including on a warm declaration-cache hit.
  # This also records those dependencies in each caller's extraction memo.
  defp installed_declarations(module, memo) do
    stamp = stamp(module, memo)
    key = {__MODULE__, :installed, module}

    case :persistent_term.get(key, nil) do
      {:declarations, ^stamp, value} ->
        value

      _stale_or_missing ->
        value = read_installed(module, memo)
        :persistent_term.put(key, {:declarations, stamp, value})
        value
    end
  end

  defp memoized(memo, key, compute) do
    case :ets.lookup(memo, key) do
      [{^key, value}] ->
        value

      [] ->
        value = compute.()
        :ets.insert(memo, {key, value})
        value
    end
  end

  @doc """
  What reading `module`'s specs from the code path (or from `source`,
  `Argus.Specs.Source`) can give, as a lowercase hex digest: its spec
  and type declarations as its beam holds them, with their line
  annotations cleared — an edit that moves
  a line of `module` moves nothing a reader of its specs computes. A
  function of `module`'s own beam alone: a spec resolved through another
  module's type (`installed/1`) is that module's read too.

  What a module's rows depend on of each module whose specs the specs
  extractor read (`Argus.Pipeline`'s `installed`): the query graph
  keys that read on this (`Argus.Graph.Reads`'s `installed_specs`).
  """
  @spec interface_digest(module(), Source.t() | nil) :: String.t()
  def interface_digest(module, source \\ nil) when is_atom(module) do
    # The module on the code path, or its beam from `source`.
    target =
      case source do
        nil ->
          {:ok, module}

        source ->
          case Source.read(source, module) do
            {:ok, binary, _stamp} -> {:ok, binary}
            :error -> :error
          end
      end

    specs =
      with {:ok, target} <- target,
           {:ok, specs} <- fetch(fn -> Code.Typespec.fetch_specs(target) end) do
        Enum.map(specs, fn {name_arity, clauses} ->
          {name_arity, Enum.map(clauses, &unannotated/1)}
        end)
      else
        _ -> :none
      end

    local =
      case target do
        {:ok, target} -> local_types(target)
        :error -> %{}
      end

    types =
      for {name_arity, {args, body}} <- local,
          into: %{},
          do: {name_arity, {Enum.map(args, &unannotated/1), unannotated(body)}}

    {specs, types}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp unannotated(form) do
    :erl_parse.map_anno(fn _anno -> :erl_anno.new(0) end, form)
  rescue
    _ -> form
  end

  @doc """
  Classifies a list of spec clauses (Erlang abstract format, as
  `Code.Typespec.fetch_specs/1` returns them) against the types of the
  module they belong to, as `{params, body}` by `{name, arity}`.
  """
  @spec shapes([tuple()], %{{atom(), arity()} => {list(), tuple()}}) :: [shape()]
  def shapes(clauses, types), do: shapes(clauses, types, nil)

  defp shapes(clauses, types, memo) do
    alts = Enum.flat_map(clauses, &clause_return(&1, {types, memo}))
    classify(alts)
  end

  # ── Reading ─────────────────────────────────────────────────────────

  defp read_beam(beam) do
    cond do
      BeamSpy.BeamFile.beam_data?(beam) -> {:ok, beam}
      File.regular?(beam) -> File.read(beam)
      true -> :error
    end
  end

  # Code.Typespec raises on a malformed chunk rather than answering
  # :error; a beam we cannot read specs from is simply unknown.
  defp fetch(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The typespec forms `Code.Typespec.fetch_specs/1` and `fetch_types/1`
  # read, from one decoding of the debug-info chunk where each of them
  # decodes it again (an Elixir module's chunk carries its whole
  # definition): an Elixir module's specs as its chunk stores them, an
  # Erlang module's abstract code.
  defp typespec_forms(module, {:debug_info_v1, backend, data}) do
    case data do
      {:elixir_v1, %{}, specs} -> {:ok, specs}
      _ -> backend.debug_info(:erlang_v1, module, data, [])
    end
  end

  defp typespec_forms(_module, _chunk), do: :error

  defp read_chunk(binary) do
    with [_ | _] = info <- :beam_lib.info(binary),
         {:ok, {_, [debug_info: chunk]}} <- :beam_lib.chunks(binary, [:debug_info]),
         do: {:ok, {info[:module], chunk}}
  end

  # `local_types/1` over forms already read.
  defp types_of(forms) do
    for {:attribute, _, kind, {name, body, args}} <- forms,
        kind in [:opaque, :type],
        into: %{},
        do: {{name, length(args)}, {args, body}}
  end

  defp local_types(module_or_binary) do
    case fetch(fn -> Code.Typespec.fetch_types(module_or_binary) end) do
      {:ok, types} ->
        Map.new(types, fn {_kind, {name, body, args}} -> {{name, length(args)}, {args, body}} end)

      :error ->
        %{}
    end
  end

  defp read_installed(module, memo) do
    with {:ok, target} <- target(module, memo),
         {:ok, specs} <- fetch(fn -> Code.Typespec.fetch_specs(target) end) do
      specs
    else
      :error -> :unknown
    end
  end

  defp installed_types(module, nil), do: stamped_types(module, nil)

  defp installed_types(module, memo),
    do: memoized(memo, {:types, module}, fn -> stamped_types(module, memo) end)

  defp stamped_types(module, memo) do
    stamp = stamp(module, memo)
    key = {__MODULE__, :types, module}

    case :persistent_term.get(key, nil) do
      {^stamp, types} ->
        types

      _stale_or_missing ->
        types =
          case target(module, memo) do
            {:ok, target} -> local_types(target)
            :error -> %{}
          end

        :persistent_term.put(key, {stamp, types})
        types
    end
  end

  # What installed specs are read from: the module on the code path, or
  # its beam from the run's source (`Argus.Specs.Source`, carried in the
  # memo), which never looks at the code path.
  defp target(module, memo) do
    case source(memo) do
      nil ->
        {:ok, module}

      source ->
        case Source.read(source, module) do
          {:ok, binary, _stamp} -> {:ok, binary}
          :error -> :error
        end
    end
  end

  defp source(nil), do: nil

  defp source(memo) do
    case :ets.lookup(memo, :specs_source) do
      [{:specs_source, source}] -> source
      [] -> nil
    end
  end

  # Which file a module would be read from, and when it was written: a
  # memoized answer is reused only while both still hold.
  defp stamp(module, memo) do
    case source(memo) do
      nil -> code_path_stamp(module)
      source -> {:source, Source.stamp(source, module)}
    end
  end

  defp code_path_stamp(module) do
    case :code.which(module) do
      path when is_list(path) ->
        Source.file_stamp(List.to_string(path))

      other ->
        other
    end
  end

  defp reduce(specs, types, memo) do
    for {{name, arity}, clauses} <- specs,
        shapes = shapes(clauses, types, memo),
        shapes != [],
        into: %{},
        do: {{name, arity}, shapes}
  end

  # ── Classification ──────────────────────────────────────────────────

  defp classify([]), do: []

  defp classify(alts) do
    [
      Enum.any?(alts, &failure?/1) && :can_fail,
      total?(alts) && :total,
      constant?(alts) && :constant,
      Enum.all?(alts, &(&1 == :none)) && :no_return,
      Enum.any?(alts, &pid?/1) && :returns_pid
    ]
    |> Enum.filter(& &1)
  end

  # One literal atom, whatever the clause: `:ok`, `true`. A clause that
  # never returns adds nothing a caller could see.
  defp constant?(alts) do
    case alts |> Enum.reject(&(&1 == :none)) |> Enum.uniq() do
      [{:atom, _}] -> true
      _ -> false
    end
  end

  defp total?(alts) do
    not Enum.any?(alts, &(failure?(&1) or &1 == :any)) and not Enum.all?(alts, &(&1 == :none))
  end

  defp failure?({:atom, atom}), do: atom in @failure_atoms

  defp failure?({:tuple, [first | _]}),
    do: Enum.any?(first, fn alt -> match?({:atom, tag} when tag in @failure_tags, alt) end)

  defp failure?(_alt), do: false

  defp pid?(:pid), do: true

  defp pid?({:tuple, [first, second | _]}),
    do: {:atom, :ok} in first and :pid in second

  defp pid?(_alt), do: false

  # ── Resolution ──────────────────────────────────────────────────────

  defp clause_return({:type, _, :fun, [_args, return]}, scope),
    do: resolve(return, %{}, scope, @max_depth)

  defp clause_return(
         {:type, _, :bounded_fun, [{:type, _, :fun, [_args, return]}, constraints]},
         scope
       ) do
    bounds =
      for {:type, _, :constraint, [{:atom, _, :is_subtype}, [{:var, _, var}, bound]]} <-
            constraints,
          into: %{},
          do: {var, bound}

    resolve(return, bounds, scope, @max_depth)
  end

  defp clause_return(_clause, _scope), do: [:any]

  @spec resolve(tuple(), map(), scope(), non_neg_integer()) :: [alt()]
  defp resolve(_type, _vars, _scope, 0), do: [:any]

  defp resolve({:type, _, :union, members}, vars, scope, depth),
    do: Enum.flat_map(members, &resolve(&1, vars, scope, depth))

  defp resolve({:ann_type, _, [_var, type]}, vars, scope, depth),
    do: resolve(type, vars, scope, depth)

  defp resolve({:paren_type, _, [type]}, vars, scope, depth),
    do: resolve(type, vars, scope, depth)

  defp resolve({:var, _, :_}, _vars, _scope, _depth), do: [:any]

  # A variable is its bound, and a bound variable resolves once: a
  # constraint that mentions itself is unknown rather than a loop.
  defp resolve({:var, _, var}, vars, scope, depth) do
    case Map.pop(vars, var) do
      {nil, _} -> [:any]
      {bound, rest} -> resolve(bound, rest, scope, depth - 1)
    end
  end

  defp resolve({:atom, _, atom}, _vars, _scope, _depth), do: [{:atom, atom}]

  defp resolve({:type, _, :tuple, :any}, _vars, _scope, _depth), do: [{:tuple, :any}]

  defp resolve({:type, _, :tuple, elements}, vars, scope, depth),
    do: [{:tuple, Enum.map(elements, &resolve(&1, vars, scope, depth - 1))}]

  defp resolve({:type, _, name, []}, _vars, _scope, _depth)
       when name in [:term, :any],
       do: [:any]

  defp resolve({:type, _, name, []}, _vars, _scope, _depth)
       when name in [:no_return, :none],
       do: [:none]

  defp resolve({:type, _, :boolean, []}, _vars, _scope, _depth),
    do: [{:atom, true}, {:atom, false}]

  defp resolve({:type, _, :pid, []}, _vars, _scope, _depth), do: [:pid]
  defp resolve({:type, _, :identifier, []}, _vars, _scope, _depth), do: [:pid, :other]

  defp resolve({:user_type, _, name, args}, vars, {types, _memo} = scope, depth) do
    case Map.fetch(types, {name, length(args)}) do
      {:ok, {params, body}} -> expand(params, args, body, vars, scope, depth)
      :error -> [:any]
    end
  end

  defp resolve(
         {:remote_type, _, [{:atom, _, mod}, {:atom, _, name}, args]},
         vars,
         {_types, memo},
         depth
       ) do
    remote = installed_types(mod, memo)

    case Map.fetch(remote, {name, length(args)}) do
      {:ok, {params, body}} ->
        args = Enum.map(args, &substitute(&1, vars))
        expand(params, args, body, %{}, {remote, memo}, depth)

      :error ->
        [:any]
    end
  end

  # Every other type — integers, lists, maps, binaries, references,
  # ports, funs, ranges, `atom()` — is a value, and none of them is a
  # failure a rule recognizes.
  defp resolve(_type, _vars, _scope, _depth), do: [:other]

  # A parameterized type's body with its parameters bound to the
  # arguments the use site gave.
  defp expand(params, args, body, vars, scope, depth) do
    bound =
      params
      |> Enum.zip(args)
      |> Enum.reduce(%{}, fn
        {{:var, _, param}, arg}, acc -> Map.put(acc, param, substitute(arg, vars))
        _other, acc -> acc
      end)

    resolve(body, bound, scope, depth - 1)
  end

  # An argument is resolved in the caller's scope; a variable it names is
  # replaced by that scope's bound before the callee's scope takes over.
  defp substitute({:var, _, var} = type, vars), do: Map.get(vars, var, type)
  defp substitute(type, _vars), do: type
end
