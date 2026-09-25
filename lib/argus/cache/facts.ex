defmodule Argus.Cache.Facts do
  @moduledoc """
  Facts extracted through a store (`Argus.Cache`), and the solves over
  them.

  ## Shards

  Each producer's rows (`Argus.Pipeline`'s producers: `:base` and each
  extractor) are kept apart, as a shard: a directory of the relation
  files it wrote, beside a manifest of each file's digest. A shard is
  keyed by everything that can change a byte of it:

    * the beams, by path and content, in the order given;
    * the code the producer runs (`Argus.Cache.Code`): its own closure
      and the base's, since it reads what the base computes;
    * the Elixir, OTP and ERTS it runs on;
    * the options that shape its rows: which relations are written and
      whether imprecision is traced;
    * for a producer that reads specs from the code path
      (`Argus.Extractors.Specs`), the environment
      (`Argus.Specs.environment_digest/1`, argus's own application
      left out) and, recorded in the manifest and checked on every hit,
      what each module it read from the code path outside that digest
      was: absent, or a beam of argus's own application with its digest.

  An extraction looks every producer up and runs the pipeline for the
  missing ones alone (`Argus.Pipeline.run_shards/3`): after an edit to
  one extractor, that extractor's shard is extracted again and every
  other one is read. A run that lost a module to a timeout keeps
  nothing — its rows depend on the machine's load.

  ## A run's facts

  A run's facts are a map from each relation file to its content's
  digest and the files that hold it — a shard's file, several shards'
  files joined, or a solve's output — with no directory until one is
  needed: a run whose solves are all kept never makes one. A solve that
  misses places in a directory only the files its program reads, as
  symbolic links into the store (`materialize/2`); on a cold run that
  was most of the store's cost, every schema relation hard-linked or
  written empty for solves that each read a few dozen. `materialize/1`
  makes the whole directory, hard links a caller can keep, put together
  as `Argus.Pipeline.Shards` joins producers: byte-identical to what
  `Argus.Pipeline.run/3` would have written.

  ## Solves

  `solve/3` keys a solve by the program, the solver and the digests of
  exactly the files the program reads (`Argus.Souffle.Cache`), and reads
  a kept one back. A stage's outputs join the run's facts by their
  content, so a solve downstream of a stage whose output came out the
  same after an edit is read back too.
  """

  alias Argus.Cache
  alias Argus.Cache.Code
  alias Argus.Pipeline
  alias Argus.Pipeline.Disassemble
  alias Argus.Pipeline.Shards
  alias Argus.Souffle

  @format "argus-shard-1"
  @manifest ".argus-shard"
  @bases_format "argus-bases-1\n"

  @enforce_keys [:store, :group, :relations]
  defstruct [:store, :group, :relations, work: nil, dir: nil, placed: %{}, complete: false]

  @typedoc """
  A relation file's content: its digest, and the files whose bytes,
  joined in order, are it.
  """
  @type source :: {digest :: String.t(), [Path.t()]}

  @typedoc """
  A run's facts: the store they are kept in, the group naming this set
  of beams' entries (the first 16 hex digits of their digest), each
  relation file's `t:source/0`, and — once a solve or `materialize/1`
  made one — a directory holding them, inside a scratch directory
  `release/1` removes: `placed` says which files it holds, how each was
  placed and from what, and `complete` whether it holds them all.
  """
  @type t :: %__MODULE__{
          store: Path.t(),
          group: String.t(),
          relations: %{String.t() => source()},
          work: Path.t() | nil,
          dir: Path.t() | nil,
          placed: %{String.t() => {:link | :symlink, [Path.t()]}},
          complete: boolean()
        }

  @doc """
  The facts of `modules` for `:base` and `extractors`, from the store's
  shards, extracting the missing ones. `opts` are
  `Argus.Pipeline.run_shards/3`'s. `{:error, {:uncacheable, reason}}`
  when a producer's code cannot be keyed (it has no beam on disk); any
  other error is the pipeline's.
  """
  @spec extract([Disassemble.module_input()], [module()], keyword(), Path.t()) ::
          {:ok, t()} | {:error, term()}
  def extract(modules, extractors, opts, store) do
    producers = [:base | Enum.uniq(extractors)]

    with {:ok, paths} <- Disassemble.resolve_paths(modules),
         beams = beams_digest(paths),
         {:ok, named} <- entries(producers, beams, opts, store) do
      looked = Enum.map(named, fn {producer, entry} -> {producer, entry, lookup(entry)} end)
      hits = for {producer, entry, :hit} <- looked, do: {producer, entry}
      misses = for {producer, entry, found} <- looked, found != :hit, do: {producer, entry}

      # A shard whose recorded reads no longer hold is replaced: its key
      # is the one the new shard is installed under.
      for {_producer, entry, :stale} <- looked, do: File.rm_rf(entry)
      facts = %__MODULE__{store: store, group: String.slice(beams, 0, 16), relations: %{}}

      bases = bases_entry(beams, store)

      with {:ok, extracted, facts} <- extract_missing(facts, paths, misses, opts, bases) do
        manifests = Map.new(hits, fn {p, entry} -> {p, {entry, read_manifest!(entry)}} end)
        {:ok, %{facts | relations: join(producers, Map.merge(manifests, extracted))}}
      end
    end
  end

  @doc """
  The digest of the beams an extraction reads: each by its path (a
  row can name it) and content, in order.
  """
  @spec beams_digest([String.t() | binary()]) :: String.t()
  def beams_digest(paths) do
    paths
    |> Enum.flat_map(fn path ->
      if BeamSpy.BeamFile.beam_data?(path),
        do: ["(beam data)", :crypto.hash(:sha256, path)],
        else: [Path.expand(path), :crypto.hash(:sha256, File.read!(path))]
    end)
    |> then(&Cache.key([@format | &1]))
  end

  # `{producer, entry}` for each producer, or why one cannot be keyed.
  defp entries(producers, beams, opts, store) do
    group = String.slice(beams, 0, 16)
    common = [@format, beams | runtime()] ++ shaping(opts)

    Enum.reduce_while(producers, {:ok, []}, fn producer, {:ok, acc} ->
      case Code.digest(producer) do
        {:ok, code} ->
          key = Cache.key(common ++ [code, environment(producer, store)])
          entry = Path.join(Cache.dir(store, :shards), "#{name(producer)}-#{group}-#{key}")
          {:cont, {:ok, [{producer, entry} | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:uncacheable, reason}}}
      end
    end)
    |> case do
      {:ok, named} -> {:ok, Enum.reverse(named)}
      error -> error
    end
  end

  defp runtime do
    [System.version(), System.otp_release(), List.to_string(:erlang.system_info(:version))]
  end

  defp shaping(opts) do
    written =
      case Keyword.get(opts, :relations, :all) do
        :all -> "all"
        {:except, names} -> "except " <> names_list(names)
        names -> names_list(names)
      end

    [written, to_string(Keyword.get(opts, :trace_imprecision, false))]
  end

  defp names_list(names), do: names |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(",")

  defp environment(producer, store) do
    if Code.reads_installed?(producer),
      do: Argus.Specs.environment_digest(exclude: [:panoptes], cache: Cache.dir(store, :ebins)),
      else: ""
  end

  defp name(:base), do: "base"
  defp name(extractor), do: inspect(extractor)

  # `:hit`, a kept shard whose recorded reads of the code path still
  # hold; `:stale`, one whose reads moved (or whose manifest cannot be
  # read); `:miss`.
  defp lookup(entry) do
    case Cache.fetch(entry) do
      {:ok, entry} ->
        with {:ok, %{reads: reads}} <- read_manifest(entry),
             true <- Enum.all?(reads, fn {name, was} -> installed(name) == was end) do
          :hit
        else
          _ -> :stale
        end

      :miss ->
        :miss
    end
  end

  defp read_manifest(entry) do
    with {:ok, bytes} <- File.read(Path.join(entry, @manifest)) do
      {:ok, :erlang.binary_to_term(bytes, [:safe])}
    end
  rescue
    ArgumentError -> {:error, :bad_manifest}
  end

  defp read_manifest!(entry) do
    {:ok, manifest} = read_manifest(entry)
    manifest
  end

  # The missing producers extracted in one run of the pipeline, each
  # into a staging directory in the store, and installed unless the run
  # lost a module. `{:ok, %{producer => {dir, manifest}}, facts}`.
  defp extract_missing(facts, _paths, [], _opts, _bases), do: {:ok, %{}, facts}

  defp extract_missing(facts, paths, misses, opts, bases) do
    with {:ok, staged} <- stage(misses) do
      run_missing(facts, paths, staged, opts, bases)
    end
  end

  # A staging directory for each missing shard; a store that cannot be
  # written to is no store.
  defp stage(misses) do
    Enum.reduce_while(misses, {:ok, []}, fn {producer, entry}, {:ok, acc} ->
      case Cache.staging(entry) do
        {:ok, staging} ->
          {:cont, {:ok, [{producer, entry, staging} | acc]}}

        {:error, reason} ->
          Enum.each(acc, fn {_p, _e, staging} -> File.rm_rf(staging) end)
          {:halt, {:error, {:uncacheable, reason}}}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      error -> error
    end
  end

  defp run_missing(facts, paths, staged, opts, bases) do
    dirs = for {producer, _entry, staging} <- staged, do: {producer, staging}
    {bases_opts, keep?} = bases_opts(bases, paths, List.keymember?(dirs, :base, 0))

    case Pipeline.run_shards(paths, dirs, opts ++ bases_opts) do
      {:ok, %{lost: lost, installed: installed, digests: digests} = info} ->
        if keep? and lost == [], do: keep_bases(bases, info.bases)
        reads = recorded_reads(installed)

        extracted =
          Map.new(staged, fn {producer, entry, staging} ->
            manifest = %{
              relations: Map.get(digests, producer, %{}),
              reads: if(Code.reads_installed?(producer), do: reads, else: [])
            }

            File.write!(Path.join(staging, @manifest), :erlang.term_to_binary(manifest))
            names = [@manifest | Map.keys(manifest.relations)]
            {producer, {settle(staging, entry, names, lost), manifest}}
          end)

        {:ok, extracted, keep_scratch(facts, lost, staged)}

      {:error, _} = error ->
        Enum.each(staged, fn {_p, _entry, staging} -> File.rm_rf(staging) end)
        error
    end
  end

  # ── Bases ───────────────────────────────────────────────────────────

  # The entry holding each module's base for these beams
  # (`Argus.Pipeline.Base`): keyed by them, the runtime and the code of
  # the base, which is what computes one — not by the options that
  # shape rows, since a base holds none.
  defp bases_entry(beams, store) do
    {:ok, code} = Code.digest(:base)
    key = Cache.key([@bases_format, beams | runtime()] ++ [code])
    Path.join(Cache.dir(store, :bases), "#{String.slice(beams, 0, 16)}-#{key}")
  end

  # What the pipeline is asked about bases, and whether to keep the
  # ones it computes. A run extracting the base's own shard computes
  # every base (the emitter's rows are no base's) and keeps none: it is
  # the first run over these beams or the first since the base's code
  # moved — every schema bump — and keeping them costs such a run a
  # tenth more for runs that may never come. A run of extractors alone
  # reads them back, or computes them and keeps them for the next one:
  # iterating on an extractor pays that once.
  defp bases_opts(_entry, _paths, true = _base_missing?), do: {[], false}

  defp bases_opts(entry, paths, false) do
    case read_bases(entry, length(paths)) do
      {:ok, kept} -> {[bases: kept], false}
      :miss -> {[keep_bases: true], true}
    end
  end

  # A module's base, or nil for one that had none, each length-prefixed
  # after the format: the file is read once and each base handed to its
  # worker as a slice of it.
  defp read_bases(entry, count) do
    with {:ok, entry} <- Cache.fetch(entry),
         {:ok, <<@bases_format, ^count::32, rest::binary>>} <- File.read(entry),
         {:ok, bases} <- split_bases(rest, count, []) do
      {:ok, bases}
    else
      _ -> :miss
    end
  end

  defp split_bases(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp split_bases(<<0::64, rest::binary>>, n, acc) when n > 0,
    do: split_bases(rest, n - 1, [nil | acc])

  defp split_bases(<<size::64, base::binary-size(size), rest::binary>>, n, acc) when n > 0,
    do: split_bases(rest, n - 1, [base | acc])

  defp split_bases(_bytes, _n, _acc), do: :error

  # Written under a staging name and installed, as every entry is; a
  # store that cannot take it goes without.
  defp keep_bases(entry, bases) do
    staging = "#{entry}.#{:os.getpid()}.#{System.unique_integer([:positive])}"

    body =
      Enum.map(bases, fn
        nil -> <<0::64>>
        base -> [<<byte_size(base)::64>>, base]
      end)

    with :ok <- Cache.mkdir(Path.dirname(entry)) |> existing(),
         :ok <- File.write(staging, [@bases_format, <<length(bases)::32>> | body]),
         :ok <- Cache.install(staging, entry) do
      :ok
    else
      _ -> File.rm(staging)
    end
  end

  defp existing({:error, :eexist}), do: :ok
  defp existing(result), do: result

  # Installed, or — when the run lost a module — left as it is, for this
  # run alone (`release/1` removes it).
  defp settle(staging, entry, names, []) do
    case Cache.install(staging, entry, names) do
      :ok -> entry
      {:error, _} -> staging
    end
  end

  defp settle(staging, _entry, _names, _lost), do: staging

  defp keep_scratch(facts, [], _staged), do: facts

  defp keep_scratch(facts, _lost, staged) do
    work = work_dir(facts)
    scratch = Path.join(work, "lost")
    File.write!(scratch, Enum.map_join(staged, "\n", &elem(&1, 2)))
    %{facts | work: work}
  end

  # Each relation file's source, the producers' files joined in order. A
  # file joined from several parts is named by its parts' digests, in
  # order: the same parts are the same bytes, so a solve keyed on it is
  # read back exactly when they are unchanged, and nothing is read to
  # say so.
  defp join(producers, manifests) do
    producers
    |> Enum.flat_map(fn producer ->
      {dir, %{relations: relations}} = Map.fetch!(manifests, producer)
      for {name, digest} <- relations, do: {name, {digest, Path.join(dir, name)}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn
      {name, [{digest, path}]} ->
        {name, {digest, [path]}}

      {name, parts} ->
        digest = Cache.key(["joined" | Enum.map(parts, &elem(&1, 0))])
        {name, {digest, Enum.map(parts, &elem(&1, 1))}}
    end)
  end

  # ── The code path a producer read ───────────────────────────────────

  # What each module read from the code path was, for those the
  # environment digest does not cover. By name: a manifest is read with
  # no new atoms made, and a module the analyzed program calls is
  # rarely one this VM knows.
  defp recorded_reads(modules) do
    for name <- modules |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
        was = installed(name),
        was != :environment,
        do: {name, was}
  end

  # A module, by name, as `Argus.Specs.installed/2` would find it:
  # absent, in the environment digest, or a beam of argus's own
  # application (its fixtures, in a test run — and the stubs of other
  # libraries' behaviours they define), by its digest with debug info.
  defp installed(name) do
    if MapSet.member?(available(), name) do
      case :code.which(String.to_atom(name)) do
        path when is_list(path) and path != [] ->
          path = List.to_string(path)

          if Path.dirname(path) == own_ebin(),
            do: {:beam, own_digest(path)},
            else: :environment

        :non_existing ->
          :absent

        # ERTS's own, which the runtime's version names.
        :preloaded ->
          :environment

        other ->
          {:other, other}
      end
    else
      :absent
    end
  end

  # Every module on the code path or loaded, by name: a module missing
  # here is absent without asking the code server, which walks the code
  # path for each (the corpus's specs extractor asks about thousands).
  defp available do
    key = {__MODULE__, :available, :erlang.phash2(:code.get_path())}

    case :persistent_term.get(key, nil) do
      nil ->
        names = MapSet.new(:code.all_available(), fn {name, _, _} -> List.to_string(name) end)
        :persistent_term.put(key, names)
        names

      names ->
        names
    end
  end

  defp own_ebin do
    case :code.lib_dir(:panoptes) do
      dir when is_list(dir) -> dir |> List.to_string() |> Path.join("ebin")
      _ -> nil
    end
  end

  defp own_digest(path) do
    stamp =
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{mtime: mtime, size: size, inode: inode}} -> {mtime, size, inode}
        {:error, reason} -> reason
      end

    key = {__MODULE__, :own_digest, path}

    case :persistent_term.get(key, nil) do
      {^stamp, digest} ->
        digest

      _ ->
        digest =
          case Argus.BeamDigest.digest(path, debug_info: true) do
            {:ok, digest} -> Base.encode16(digest, case: :lower)
            {:error, reason} -> {:unreadable, reason}
          end

        :persistent_term.put(key, {stamp, digest})
        digest
    end
  end

  # ── A directory ─────────────────────────────────────────────────────

  @doc """
  The facts in a directory: `facts.dir`, made on first call — every
  relation file linked from the store (hard links, copies across
  volumes), every schema relation without rows an empty file, as
  `Argus.Pipeline.run/3` leaves them. A file a solve placed there as a
  symbolic link (`materialize/2`) is linked again, so the directory
  outlives the store's entries: it is the caller's to keep.
  """
  @spec materialize(t()) :: {:ok, t()} | {:error, term()}
  def materialize(%__MODULE__{complete: true} = facts), do: {:ok, facts}

  def materialize(%__MODULE__{} = facts) do
    names = Enum.uniq(Map.keys(facts.relations) ++ MapSet.to_list(schema_files()))

    with {:ok, facts} <- place(facts, names, :link) do
      {:ok, %{facts | complete: true}}
    end
  end

  @doc """
  The facts in a directory holding at least the relation files `names`
  (a schema relation without rows as an empty file; a name the facts do
  not hold, such as a stage not derived yet, left out), for a solve of
  this run: `facts.dir`, made on first call, with each file not there
  yet placed as a symbolic link into the store. Only what a solve reads
  is placed, and a link is a fraction of a hard link's cost; the links
  last as long as the entries they name, which a run touches (`Argus.Cache`).
  """
  @spec materialize(t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def materialize(%__MODULE__{} = facts, names), do: place(facts, names, :symlink)

  defp place(facts, names, mode) do
    with {:ok, facts} <- ensure_dir(facts) do
      Enum.reduce_while(names, {:ok, facts}, fn name, {:ok, facts} ->
        case place_one(facts, name, mode) do
          {:ok, facts} -> {:cont, {:ok, facts}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # A file already there from the same source stays (a hard link serves
  # a request for a symbolic one); a missing one is made in place, and
  # one from another source — a stage's output over what the directory
  # held — is made beside it and renamed over it.
  defp place_one(facts, name, mode) do
    case sources(facts, name) do
      :none ->
        {:ok, facts}

      {:ok, paths} ->
        target = Path.join(facts.dir, name)

        result =
          case Map.fetch(facts.placed, name) do
            {:ok, {placed_mode, ^paths}} when placed_mode == mode or placed_mode == :link -> :kept
            {:ok, _other} -> Shards.place(paths, target, mode)
            :error -> create(paths, target, mode)
          end

        case result do
          :kept -> {:ok, facts}
          :ok -> {:ok, %{facts | placed: Map.put(facts.placed, name, {mode, paths})}}
          {:error, _} = error -> error
        end
    end
  end

  # What a relation file holds: its source's files, none for a schema
  # relation without rows, or `:none` when the facts do not hold it.
  defp sources(%__MODULE__{relations: relations}, name) do
    case Map.fetch(relations, name) do
      {:ok, {_digest, paths}} -> {:ok, paths}
      :error -> if MapSet.member?(schema_files(), name), do: {:ok, []}, else: :none
    end
  end

  # A file made where none is: a link made in place, an empty file
  # written. A relation joined from parts is written whole beside it and
  # renamed (`Argus.Pipeline.Shards.place/3`).
  defp create([], target, _mode) do
    case File.write(target, "") do
      :ok -> :ok
      {:error, reason} -> {:error, {:place_failed, target, reason}}
    end
  end

  # A solve fanned out beside others places only what `prepare/3` did
  # not; should two place the same file (a kept solve pruned between the
  # two), the one that finds it there takes it: within one directory a
  # name has one source.
  defp create([path], target, :symlink) do
    case File.ln_s(path, target) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:place_failed, target, reason}}
    end
  end

  defp create([path], target, :link) do
    case File.ln(path, target) do
      :ok ->
        :ok

      {:error, :eexist} ->
        :ok

      {:error, _} ->
        case File.cp(path, target) do
          :ok -> :ok
          {:error, reason} -> {:error, {:place_failed, target, reason}}
        end
    end
  end

  defp create(paths, target, mode), do: Shards.place(paths, target, mode)

  defp ensure_dir(%__MODULE__{dir: dir} = facts) when is_binary(dir), do: {:ok, facts}

  defp ensure_dir(%__MODULE__{} = facts) do
    work = work_dir(facts)
    dir = Path.join(work, "facts")

    case File.mkdir(dir) do
      :ok -> {:ok, %{facts | work: work, dir: dir}}
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp work_dir(%__MODULE__{work: work}) when is_binary(work), do: work

  defp work_dir(%__MODULE__{store: store}) do
    work = Path.join([store, "work", "#{:os.getpid()}-#{System.unique_integer([:positive])}"])

    case Cache.mkdir(work) do
      :ok -> work
      {:error, reason} -> raise File.Error, reason: reason, action: "make directory", path: work
    end
  end

  @doc """
  The facts after files of their directory were written in place (the
  `prior_*` relations `Argus.Priors` derives into it): each of `names`
  joins them by its content now, from the directory.
  """
  @spec refresh(t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def refresh(%__MODULE__{dir: dir} = facts, names) when is_binary(dir) do
    Enum.reduce_while(names, {:ok, facts}, fn name, {:ok, facts} ->
      path = Path.join(dir, name)

      case Cache.file_digest(path) do
        {:ok, digest} ->
          {:cont,
           {:ok,
            %{
              facts
              | relations: Map.put(facts.relations, name, {digest, [path]}),
                placed: Map.put(facts.placed, name, {:link, [path]})
            }}}

        {:error, reason} ->
          {:halt, {:error, {:digest_failed, name, reason}}}
      end
    end)
  end

  @doc """
  Removes what the facts made outside the store: the directory and any
  shards a run that lost a module kept for itself.
  """
  @spec release(t()) :: :ok
  def release(%__MODULE__{work: nil}), do: :ok

  def release(%__MODULE__{work: work} = facts) do
    case File.read(Path.join(work, "lost")) do
      {:ok, dirs} -> dirs |> String.split("\n", trim: true) |> Enum.each(&File.rm_rf/1)
      {:error, _} -> :ok
    end

    remove_work(facts)
    :ok
  end

  # The directory holds the files placed in it, removed by name: walking
  # it asks after each file first, as long again on a busy disk. Anything
  # else there — a file a solve fanned out beside others placed, which
  # this copy of the facts does not name, or the list of a lost run's
  # shards — leaves a directory that will not go, and it is walked.
  defp remove_work(%__MODULE__{work: work, dir: dir, placed: placed}) do
    if dir, do: Enum.each(Map.keys(placed), &File.rm(Path.join(dir, &1)))

    with :ok <- if(dir, do: File.rmdir(dir), else: :ok),
         :ok <- File.rmdir(work) do
      :ok
    else
      {:error, _} -> File.rm_rf(work)
    end
  end

  # ── Solves ──────────────────────────────────────────────────────────

  @doc """
  The digest of a relation file's content: its source's, an empty
  file's for a schema relation no producer wrote, `"absent"` for any
  other (a stage not derived yet).
  """
  @spec digest(t(), String.t()) :: String.t()
  def digest(%__MODULE__{relations: relations}, name) do
    case Map.fetch(relations, name) do
      {:ok, {digest, _paths}} -> digest
      :error -> if MapSet.member?(schema_files(), name), do: empty_digest(), else: "absent"
    end
  end

  @doc """
  The kept solve `rules_path` would be read from: `{:ok, entry}`, or
  why the program's inputs could not be resolved.
  """
  @spec entry(t(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def entry(%__MODULE__{} = facts, rules_path, opts) do
    with {:ok, entry, _inputs} <- keyed(facts, rules_path, opts), do: {:ok, entry}
  end

  # The entry, and the relation files the program reads.
  defp keyed(facts, rules_path, opts) do
    with {:ok, bin} <- souffle_bin(opts),
         {:ok, inputs} <-
           Souffle.input_files(rules_path,
             souffle_bin: bin,
             programs: Cache.dir(facts.store, :programs)
           ) do
      digests = Enum.map(inputs, &{&1, digest(facts, &1)})
      solves = Cache.dir(facts.store, :solves)
      {:ok, Souffle.Cache.named(solves, facts.group, rules_path, bin, digests), inputs}
    end
  end

  @doc """
  Whether a solve of every one of `rules_paths` is kept (touching each,
  as a hit does).
  """
  @spec kept_solves?(t(), [Path.t()], keyword()) :: boolean()
  def kept_solves?(%__MODULE__{} = facts, rules_paths, opts) do
    Enum.all?(rules_paths, fn rules_path ->
      case entry(facts, rules_path, opts) do
        {:ok, entry} -> match?({:ok, _}, Cache.fetch(entry))
        {:error, _} -> false
      end
    end)
  end

  @doc """
  Readies the solves of `rules_paths` to run side by side over the
  facts: when one of them is not kept, the directory holds every file
  the ones not kept read (`materialize/2`), so none of them places a
  file while another reads the directory. The facts are returned as
  they are when every solve is kept, and a program whose inputs cannot
  be resolved is left to its solve to report.
  """
  @spec prepare(t(), [Path.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(%__MODULE__{} = facts, rules_paths, opts) do
    missing =
      for rules_path <- rules_paths,
          {:ok, entry, inputs} <- [keyed(facts, rules_path, opts)],
          not File.exists?(entry),
          input <- inputs,
          uniq: true,
          do: input

    if missing == [], do: {:ok, facts}, else: materialize(facts, missing)
  end

  @doc """
  Solves `rules_path` over the facts, or reads the kept solve back:
  `{:ok, results, facts}` with the results as `Argus.Souffle.run/3`
  returns them, and the facts with any `.facts` file the program writes
  (a stage's) in place of what they held — in the directory too, when
  it held that file. A miss solves over `facts.dir`, placing there
  first what the program reads (`materialize/2`). Honors `:souffle_bin`
  and `:souffle_timeout`.
  """
  @spec solve(t(), Path.t(), keyword()) :: {:ok, Souffle.result(), t()} | {:error, term()}
  def solve(%__MODULE__{} = facts, rules_path, opts) do
    with {:ok, entry, inputs} <- keyed(facts, rules_path, opts) do
      case Cache.fetch(entry) do
        {:ok, entry} ->
          with {:ok, results} <- Souffle.read_outputs(entry),
               {:ok, facts} <- put_outputs(facts, entry) do
            {:ok, results, facts}
          end

        :miss ->
          solve_and_keep(facts, entry, inputs, rules_path, opts)
      end
    end
  end

  # A directory made for this solve alone goes with a failure.
  defp solve_and_keep(facts, entry, inputs, rules_path, opts) do
    case materialize(facts, inputs) do
      {:ok, placed} ->
        case solve_into(placed, entry, rules_path, opts) do
          {:ok, _results, _facts} = ok ->
            ok

          {:error, _} = error ->
            if facts.work == nil, do: release(placed)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp solve_into(facts, entry, rules_path, opts) do
    with {:ok, staging} <- Cache.staging(entry) do
      solve_opts =
        opts
        |> Keyword.take([:souffle_bin, :souffle_timeout])
        |> Keyword.put(:output_dir, staging)

      case Souffle.run(facts.dir, rules_path, solve_opts) do
        {:ok, results} ->
          case Souffle.Cache.install(staging, entry) do
            :ok ->
              with {:ok, facts} <- put_outputs(facts, entry), do: {:ok, results, facts}

            {:error, _} = error ->
              File.rm_rf(staging)
              error
          end

        {:error, _} = error ->
          File.rm_rf(staging)
          error
      end
    end
  end

  # A stage's outputs (the `.facts` files a program writes) join the
  # facts by their content, and replace what the directory held: in a
  # complete directory every one, in one a solve placed files into
  # only those it placed (the others are placed when a solve reads
  # them).
  defp put_outputs(facts, entry) do
    with {:ok, digests} <- Souffle.Cache.manifest(entry) do
      outputs =
        for {name, digest} <- digests, String.ends_with?(name, ".facts"), do: {name, digest}

      Enum.reduce_while(outputs, {:ok, facts}, fn {name, digest}, {:ok, facts} ->
        path = Path.join(entry, name)
        facts = %{facts | relations: Map.put(facts.relations, name, {digest, [path]})}

        case place_output(facts, name) do
          {:ok, facts} -> {:cont, {:ok, facts}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp place_output(%__MODULE__{dir: nil} = facts, _name), do: {:ok, facts}
  defp place_output(%__MODULE__{complete: true} = facts, name), do: place_one(facts, name, :link)

  defp place_output(%__MODULE__{} = facts, name) do
    case Map.fetch(facts.placed, name) do
      {:ok, {mode, _paths}} -> place_one(facts, name, mode)
      :error -> {:ok, facts}
    end
  end

  defp souffle_bin(opts) do
    case Keyword.get(opts, :souffle_bin) || Souffle.executable() do
      nil -> {:error, :souffle_not_found}
      bin -> {:ok, bin}
    end
  end

  @doc """
  The content of the facts' `extraction_error.facts`, as a directory of
  them would hold it (`Argus.Findings.extraction_errors/1` reads it).
  """
  @spec extraction_errors(t()) :: binary()
  def extraction_errors(%__MODULE__{relations: relations}) do
    case Map.fetch(relations, "extraction_error.facts") do
      {:ok, {_digest, paths}} -> Enum.map_join(paths, &File.read!/1)
      :error -> ""
    end
  end

  defp schema_files do
    key = {__MODULE__, :schema_files}

    case :persistent_term.get(key, nil) do
      nil ->
        files = MapSet.new(Argus.Schema.names(), &"#{&1}.facts")
        :persistent_term.put(key, files)
        files

      files ->
        files
    end
  end

  defp empty_digest, do: Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
end
