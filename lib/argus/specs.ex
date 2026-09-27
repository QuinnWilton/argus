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
  which asks the code path about each module once. Results that depend on
  the code path depend on the installed OTP, Elixir and dependencies:
  `environment_digest/1` names them, for caches keyed on extraction
  output.
  """

  require Record
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
    stamp = stamp(module)
    key = {__MODULE__, :installed, module}

    case :persistent_term.get(key, nil) do
      {^stamp, value} ->
        value

      _stale_or_missing ->
        value = read_installed(module, memo)
        :persistent_term.put(key, {stamp, value})
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
  What reading `module`'s specs from the code path can give, as a
  lowercase hex digest: its spec and type declarations as its beam
  holds them, with their line annotations cleared — an edit that moves
  a line of `module` moves nothing a reader of its specs computes. A
  function of `module`'s own beam alone: a spec resolved through another
  module's type (`installed/1`) is that module's read too.

  What a module's rows depend on of each module whose specs the specs
  extractor read (`Argus.Pipeline`'s `installed`): the query graph
  keys that read on this (`Argus.Graph.Reads`'s `installed_specs`).
  """
  @spec interface_digest(module()) :: String.t()
  def interface_digest(module) when is_atom(module) do
    specs =
      case fetch(fn -> Code.Typespec.fetch_specs(module) end) do
        {:ok, specs} ->
          Enum.map(specs, fn {name_arity, clauses} ->
            {name_arity, Enum.map(clauses, &unannotated/1)}
          end)

        :error ->
          :none
      end

    types =
      for {name_arity, {args, body}} <- stamped_types(module),
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

  @doc """
  A digest of what `installed/1` can read: every application on the code
  path, by name and version, and — for an application outside the
  OTP and Elixir installations — by the contents of its beams. Two VMs
  with equal digests read the same specs for any module an application
  ships.

  A version alone names the code of an installed OTP or Elixir
  application, but not of a dependency: a path or git dependency, or an
  umbrella sibling, changes its beams (and its specs) without moving its
  version. Hashing those beams costs one read of each, done in parallel.
  Each beam is hashed by `Argus.BeamDigest` with its debug info, which
  is where the specs are read from, and without the directory it was
  built in: a dependency built in two checkouts of one project digests
  the same.

  The hashes are kept per ebin, under a stamp of its beams' stats (name,
  modification time, size, inode): in the VM, and — with `:cache` — on
  disk, so a fresh VM stats the beams rather than reading them. An ebin
  holding a beam written within the last two seconds is hashed every
  time and kept nowhere: a stamp cannot tell two writes within one
  second apart. The digest itself is kept per code path and `:exclude`
  list, and looked at again at most once a second.

  ## Options

    * `:exclude` — applications whose beams the digest leaves out (they
      are still named, with their version). A caller that tracks some
      applications' beams itself — the program under analysis, or its
      own code — excludes them, so an edit to one does not move the
      digest of everything else.
    * `:cache` — a directory to keep each ebin's hashes in across VMs
      (`Argus.Cache.Facts` passes its store's `ebins/`).
  """
  # How long a kept environment digest is trusted without a look.
  @recheck_ms 1_000

  @spec environment_digest(keyword()) :: String.t()
  def environment_digest(opts \\ []) do
    exclude = opts |> Keyword.get(:exclude, []) |> Enum.sort() |> Enum.uniq()
    cache = Keyword.get(opts, :cache)
    key = {__MODULE__, :environment_digest, :code.get_path(), exclude}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {digest, checked} ->
        if now - :atomics.get(checked, 1) < @recheck_ms do
          digest
        else
          case compute_environment_digest(exclude, cache) do
            ^digest ->
              :atomics.put(checked, 1, now)
              digest

            moved ->
              keep_environment_digest(key, moved, now)
          end
        end

      nil ->
        keep_environment_digest(key, compute_environment_digest(exclude, cache), now)
    end
  end

  @doc """
  Every beam in each of `ebins`, by name and `Argus.BeamDigest` with its
  debug info, sorted by name: what `environment_digest/1` keys a
  dependency's code by, for a caller that keys an application it
  leaves out of that digest itself (scry keys argus's own beams). A
  beam that cannot be read is named with the reason instead.

  Kept as `environment_digest/1` keeps them: per ebin, under a stamp of
  its beams' stats, in the VM and — with `:cache` — on disk, so a fresh
  VM stats the beams rather than reading them; an ebin holding a beam
  written within the last two seconds is hashed every time.
  """
  @spec ebin_digests([Path.t()], keyword()) :: %{Path.t() => [{String.t(), term()}]}
  def ebin_digests(ebins, opts \\ []) when is_list(ebins),
    do: beam_digests(ebins, Keyword.get(opts, :cache))

  defp keep_environment_digest(key, digest, now) do
    checked = :atomics.new(1, signed: true)
    :atomics.put(checked, 1, now)
    :persistent_term.put(key, {digest, checked})
    digest
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
    case fetch(fn -> Code.Typespec.fetch_specs(module) end) do
      {:ok, specs} -> reduce(specs, installed_types(module, memo), memo)
      :error -> :unknown
    end
  end

  defp installed_types(module, nil), do: stamped_types(module)

  defp installed_types(module, memo),
    do: memoized(memo, {:types, module}, fn -> stamped_types(module) end)

  defp stamped_types(module) do
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

  # ── Environment ─────────────────────────────────────────────────────

  defp compute_environment_digest(exclude, cache) do
    stable = stable_roots()

    apps =
      for dir <- :code.get_path(),
          dir = List.to_string(dir),
          app_file <- Path.wildcard(Path.join(dir, "*.app")),
          {:ok, [{:application, app, props}]} <- [:file.consult(app_file)],
          uniq: true,
          do: {app, to_string(Keyword.get(props, :vsn, "")), dir}

    apps = Enum.sort(apps)

    hashed =
      for {app, _vsn, dir} <- apps,
          app not in exclude,
          not Enum.any?(stable, &under?(dir, &1)),
          into: MapSet.new(),
          do: dir

    digests = beam_digests(hashed, cache)

    apps
    |> Enum.map(fn {app, vsn, dir} ->
      if MapSet.member?(hashed, dir),
        do: {app, vsn, Map.get(digests, dir, [])},
        else: {app, vsn}
    end)
    |> Enum.uniq()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Where a version names the code: the OTP installation and Elixir's.
  defp stable_roots do
    otp = :code.root_dir() |> List.to_string() |> Path.expand()

    case :code.lib_dir(:elixir) do
      {:error, _} -> [otp]
      dir -> [otp, dir |> List.to_string() |> Path.expand() |> Path.dirname()]
    end
  end

  defp under?(dir, root) do
    dir = Path.expand(dir)
    dir == root or String.starts_with?(dir, root <> "/")
  end

  # Every beam in each of `ebins`, by name and `Argus.BeamDigest`, as
  # `%{ebin => [{name, hash}]}` sorted by name: each ebin's as kept under
  # the stamp of its beams, and the rest hashed. The reads are the cost,
  # so they run in parallel across every ebin hashed at once.
  defp beam_digests(ebins, cache) do
    now = System.os_time(:second)

    {kept, missing} =
      ebins
      |> Enum.map(fn ebin -> {ebin, ebin_stamp(ebin, now)} end)
      |> Enum.map(fn {ebin, stamp} -> {ebin, stamp, kept_digests(ebin, stamp, cache)} end)
      |> Enum.split_with(fn {_ebin, _stamp, found} -> found != :miss end)

    hashed =
      missing
      |> Enum.flat_map(fn {ebin, {beams, _stats, _racy?}, :miss} ->
        Enum.map(beams, &{ebin, &1})
      end)
      |> Task.async_stream(
        fn {ebin, beam} ->
          content =
            case Argus.BeamDigest.digest(beam, debug_info: true) do
              {:ok, hash} -> hash
              {:error, reason} -> reason
            end

          {ebin, {Path.basename(beam), content}}
        end,
        timeout: :infinity
      )
      |> Enum.group_by(fn {:ok, {ebin, _}} -> ebin end, fn {:ok, {_, entry}} -> entry end)

    for {ebin, stamp, :miss} <- missing do
      entries = hashed |> Map.get(ebin, []) |> Enum.sort()
      keep_digests(ebin, stamp, entries, cache)
      {ebin, entries}
    end
    |> Map.new()
    |> Map.merge(Map.new(kept, fn {ebin, _stamp, {:ok, entries}} -> {ebin, entries} end))
  end

  @racy_seconds 2
  @ebin_format "argus-ebin-digests-1"

  # An ebin's beams and the stamp of them: each one's name, modification
  # time, size and inode, and whether one was written too recently to
  # tell a later write within the same second apart.
  defp ebin_stamp(ebin, now) do
    beams = ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort()

    stats =
      for beam <- beams do
        case File.stat(beam, time: :posix) do
          {:ok, %File.Stat{mtime: mtime, size: size, inode: inode}} ->
            {Path.basename(beam), mtime, size, inode}

          {:error, reason} ->
            {Path.basename(beam), reason}
        end
      end

    racy? =
      Enum.any?(stats, fn
        {_name, mtime, _size, _inode} -> mtime >= now - @racy_seconds
        _unreadable -> true
      end)

    {beams, stats, racy?}
  end

  # `{:ok, entries}` kept for this stamp, in the VM or in `cache`, or
  # `:miss`.
  defp kept_digests(_ebin, {_beams, _stats, true}, _cache), do: :miss

  defp kept_digests(ebin, {_beams, stats, false}, cache) do
    case :persistent_term.get({__MODULE__, :ebin, ebin}, nil) do
      {^stats, entries} ->
        {:ok, entries}

      _ ->
        # Touched as a store's hit is, so retention sees it in use.
        with path when is_binary(path) <- ebin_entry(ebin, stats, cache),
             :ok <- touch(path),
             {:ok, bytes} <- File.read(path),
             {:ok, entries} when is_list(entries) <- safe_decode(bytes) do
          :persistent_term.put({__MODULE__, :ebin, ebin}, {stats, entries})
          {:ok, entries}
        else
          _ -> :miss
        end
    end
  end

  # `Argus.Cache.fetch/1`'s touch, which the store's code stays out of
  # every producer's key to keep: first, and one change of the times
  # that finds the entry or fails. Read first and touched after, a prune
  # in between left an empty file at the entry's name (`File.touch/1`
  # makes one), which nothing wrote again.
  defp touch(path) do
    now = System.os_time(:second)
    :file.write_file_info(path, file_info(mtime: now, atime: now), [{:time, :posix}])
  end

  # Kept in the VM and in `cache` unless the stamp is racy; a cache that
  # cannot be written to goes without. Only a miss comes here, so what
  # is at the entry's name, if anything, could not be read as digests:
  # it is replaced, never taken for an answer because it is there.
  defp keep_digests(_ebin, {_beams, _stats, true}, _entries, _cache), do: :ok

  defp keep_digests(ebin, {_beams, stats, false}, entries, cache) do
    :persistent_term.put({__MODULE__, :ebin, ebin}, {stats, entries})

    with path when is_binary(path) <- ebin_entry(ebin, stats, cache),
         :ok <- File.mkdir_p(cache) do
      staging = "#{path}.#{:os.getpid()}.#{System.unique_integer([:positive])}"

      with :ok <- File.write(staging, :erlang.term_to_binary(entries)),
           :ok <- File.rename(staging, path) do
        :ok
      else
        _ -> File.rm(staging)
      end
    end

    :ok
  end

  # `<application>-<key>`: the ebin's application directory and a
  # digest of the ebin's path and stamp.
  defp ebin_entry(_ebin, _stats, nil), do: nil

  defp ebin_entry(ebin, stats, cache) do
    key =
      :crypto.hash(:sha256, :erlang.term_to_binary({@ebin_format, ebin, stats}))
      |> Base.encode16(case: :lower)

    Path.join(cache, "#{ebin |> Path.dirname() |> Path.basename()}-#{key}")
  end

  defp safe_decode(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    ArgumentError -> :error
  end
end
