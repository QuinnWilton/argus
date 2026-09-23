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
  from, so a recompiled dependency is read again. Results that depend on
  the code path depend on the installed OTP, Elixir and dependencies:
  `environment_digest/0` names them, for caches keyed on extraction
  output.
  """

  @max_depth 4

  @typedoc "A normalized return shape."
  @type shape :: :can_fail | :total | :no_return | :returns_pid

  @typedoc "Each specced function's shapes; a function absent here is unknown."
  @type returns :: %{{atom(), arity()} => [shape()]}

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
  @spec of_beam(Path.t() | binary()) :: {:ok, returns()} | :error
  def of_beam(beam) when is_binary(beam) do
    with {:ok, binary} <- read_beam(beam),
         {:ok, specs} <- fetch(fn -> Code.Typespec.fetch_specs(binary) end) do
      types = local_types(binary)
      {:ok, reduce(specs, types)}
    end
  end

  @doc """
  The shapes of `module`'s specced functions as installed on the code
  path, or `:unknown` when it is not there or carries no specs.
  Memoized per module and file.
  """
  @spec installed(module()) :: returns() | :unknown
  def installed(module) when is_atom(module) do
    stamp = stamp(module)
    key = {__MODULE__, :installed, module}

    case :persistent_term.get(key, nil) do
      {^stamp, value} ->
        value

      _stale_or_missing ->
        value = read_installed(module)
        :persistent_term.put(key, {stamp, value})
        value
    end
  end

  @doc """
  Classifies a list of spec clauses (Erlang abstract format, as
  `Code.Typespec.fetch_specs/1` returns them) against the types of the
  module they belong to, as `{params, body}` by `{name, arity}`.
  """
  @spec shapes([tuple()], %{{atom(), arity()} => {list(), tuple()}}) :: [shape()]
  def shapes(clauses, types) do
    alts = Enum.flat_map(clauses, &clause_return(&1, types))
    classify(alts)
  end

  @doc """
  A digest of what `installed/1` can read: the name and version of every
  application on the code path. Two VMs with equal digests read the same
  specs for any module an application ships.
  """
  @spec environment_digest() :: String.t()
  def environment_digest do
    key = {__MODULE__, :environment_digest, :code.get_path()}

    case :persistent_term.get(key, nil) do
      nil ->
        digest = compute_environment_digest()
        :persistent_term.put(key, digest)
        digest

      digest ->
        digest
    end
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

  defp local_types(module_or_binary) do
    case fetch(fn -> Code.Typespec.fetch_types(module_or_binary) end) do
      {:ok, types} ->
        Map.new(types, fn {_kind, {name, body, args}} -> {{name, length(args)}, {args, body}} end)

      :error ->
        %{}
    end
  end

  defp read_installed(module) do
    case fetch(fn -> Code.Typespec.fetch_specs(module) end) do
      {:ok, specs} -> reduce(specs, installed_types(module))
      :error -> :unknown
    end
  end

  defp installed_types(module) do
    stamp = stamp(module)
    key = {__MODULE__, :types, module}

    case :persistent_term.get(key, nil) do
      {^stamp, types} ->
        types

      _stale_or_missing ->
        types = local_types(module)
        :persistent_term.put(key, {stamp, types})
        types
    end
  end

  # Which file a module would be read from, and when it was written: a
  # memoized answer is reused only while both still hold.
  defp stamp(module) do
    case :code.which(module) do
      path when is_list(path) ->
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime, size: size}} -> {path, mtime, size}
          {:error, _} -> {path, nil, nil}
        end

      other ->
        other
    end
  end

  defp reduce(specs, types) do
    for {{name, arity}, clauses} <- specs,
        shapes = shapes(clauses, types),
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
      Enum.all?(alts, &(&1 == :none)) && :no_return,
      Enum.any?(alts, &pid?/1) && :returns_pid
    ]
    |> Enum.filter(& &1)
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

  defp clause_return({:type, _, :fun, [_args, return]}, types),
    do: resolve(return, %{}, types, @max_depth)

  defp clause_return(
         {:type, _, :bounded_fun, [{:type, _, :fun, [_args, return]}, constraints]},
         types
       ) do
    bounds =
      for {:type, _, :constraint, [{:atom, _, :is_subtype}, [{:var, _, var}, bound]]} <-
            constraints,
          into: %{},
          do: {var, bound}

    resolve(return, bounds, types, @max_depth)
  end

  defp clause_return(_clause, _types), do: [:any]

  @spec resolve(tuple(), map(), map(), non_neg_integer()) :: [alt()]
  defp resolve(_type, _vars, _types, 0), do: [:any]

  defp resolve({:type, _, :union, members}, vars, types, depth),
    do: Enum.flat_map(members, &resolve(&1, vars, types, depth))

  defp resolve({:ann_type, _, [_var, type]}, vars, types, depth),
    do: resolve(type, vars, types, depth)

  defp resolve({:paren_type, _, [type]}, vars, types, depth),
    do: resolve(type, vars, types, depth)

  defp resolve({:var, _, :_}, _vars, _types, _depth), do: [:any]

  # A variable is its bound, and a bound variable resolves once: a
  # constraint that mentions itself is unknown rather than a loop.
  defp resolve({:var, _, var}, vars, types, depth) do
    case Map.pop(vars, var) do
      {nil, _} -> [:any]
      {bound, rest} -> resolve(bound, rest, types, depth - 1)
    end
  end

  defp resolve({:atom, _, atom}, _vars, _types, _depth), do: [{:atom, atom}]

  defp resolve({:type, _, :tuple, :any}, _vars, _types, _depth), do: [{:tuple, :any}]

  defp resolve({:type, _, :tuple, elements}, vars, types, depth),
    do: [{:tuple, Enum.map(elements, &resolve(&1, vars, types, depth - 1))}]

  defp resolve({:type, _, name, []}, _vars, _types, _depth)
       when name in [:term, :any],
       do: [:any]

  defp resolve({:type, _, name, []}, _vars, _types, _depth)
       when name in [:no_return, :none],
       do: [:none]

  defp resolve({:type, _, :boolean, []}, _vars, _types, _depth),
    do: [{:atom, true}, {:atom, false}]

  defp resolve({:type, _, :pid, []}, _vars, _types, _depth), do: [:pid]
  defp resolve({:type, _, :identifier, []}, _vars, _types, _depth), do: [:pid, :other]

  defp resolve({:user_type, _, name, args}, vars, types, depth) do
    case Map.fetch(types, {name, length(args)}) do
      {:ok, {params, body}} -> expand(params, args, body, vars, types, depth)
      :error -> [:any]
    end
  end

  defp resolve({:remote_type, _, [{:atom, _, mod}, {:atom, _, name}, args]}, vars, _types, depth) do
    remote = installed_types(mod)

    case Map.fetch(remote, {name, length(args)}) do
      {:ok, {params, body}} ->
        args = Enum.map(args, &substitute(&1, vars))
        expand(params, args, body, %{}, remote, depth)

      :error ->
        [:any]
    end
  end

  # Every other type — integers, lists, maps, binaries, references,
  # ports, funs, ranges, `atom()` — is a value, and none of them is a
  # failure a rule recognizes.
  defp resolve(_type, _vars, _types, _depth), do: [:other]

  # A parameterized type's body with its parameters bound to the
  # arguments the use site gave.
  defp expand(params, args, body, vars, types, depth) do
    bound =
      params
      |> Enum.zip(args)
      |> Enum.reduce(%{}, fn
        {{:var, _, param}, arg}, acc -> Map.put(acc, param, substitute(arg, vars))
        _other, acc -> acc
      end)

    resolve(body, bound, types, depth - 1)
  end

  # An argument is resolved in the caller's scope; a variable it names is
  # replaced by that scope's bound before the callee's scope takes over.
  defp substitute({:var, _, var} = type, vars), do: Map.get(vars, var, type)
  defp substitute(type, _vars), do: type

  # ── Environment ─────────────────────────────────────────────────────

  defp compute_environment_digest do
    apps =
      for dir <- :code.get_path(),
          app_file <- Path.wildcard(Path.join(List.to_string(dir), "*.app")),
          {:ok, [{:application, app, props}]} <- [:file.consult(app_file)],
          uniq: true,
          do: {app, to_string(Keyword.get(props, :vsn, ""))}

    apps
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
