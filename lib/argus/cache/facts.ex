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
  needed (`materialize/1`): a run whose solves are all kept never makes
  one. A directory made is hard links into the store (a copy across
  volumes), put together as `Argus.Pipeline.Shards` joins producers, so
  it is byte-identical to what `Argus.Pipeline.run/3` would have
  written.

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

  @enforce_keys [:store, :group, :relations]
  defstruct [:store, :group, :relations, work: nil, dir: nil]

  @typedoc """
  A relation file's content: its digest, and the files whose bytes,
  joined in order, are it.
  """
  @type source :: {digest :: String.t(), [Path.t()]}

  @typedoc """
  A run's facts: the store they are kept in, the group naming this set
  of beams' entries (the first 16 hex digits of their digest), each
  relation file's `t:source/0`, and — once `materialize/1` made one — a
  directory holding them, inside a scratch directory `release/1`
  removes.
  """
  @type t :: %__MODULE__{
          store: Path.t(),
          group: String.t(),
          relations: %{String.t() => source()},
          work: Path.t() | nil,
          dir: Path.t() | nil
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

      with {:ok, extracted, facts} <- extract_missing(facts, paths, misses, opts) do
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
          key = Cache.key(common ++ [code, environment(producer)])
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
        names -> names |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(",")
      end

    [written, to_string(Keyword.get(opts, :trace_imprecision, false))]
  end

  defp environment(producer) do
    if Code.reads_installed?(producer),
      do: Argus.Specs.environment_digest(exclude: [:panoptes]),
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
  defp extract_missing(facts, _paths, [], _opts), do: {:ok, %{}, facts}

  defp extract_missing(facts, paths, misses, opts) do
    with {:ok, staged} <- stage(misses) do
      run_missing(facts, paths, staged, opts)
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

  defp run_missing(facts, paths, staged, opts) do
    dirs = for {producer, _entry, staging} <- staged, do: {producer, staging}

    case Pipeline.run_shards(paths, dirs, opts) do
      {:ok, %{lost: lost, installed: installed}} ->
        reads = recorded_reads(installed)

        extracted =
          Map.new(staged, fn {producer, entry, staging} ->
            manifest = %{
              relations: digest_files(staging),
              reads: if(Code.reads_installed?(producer), do: reads, else: [])
            }

            File.write!(Path.join(staging, @manifest), :erlang.term_to_binary(manifest))
            {producer, {settle(staging, entry, lost), manifest}}
          end)

        {:ok, extracted, keep_scratch(facts, lost, staged)}

      {:error, _} = error ->
        Enum.each(staged, fn {_p, _entry, staging} -> File.rm_rf(staging) end)
        error
    end
  end

  # Installed, or — when the run lost a module — left as it is, for this
  # run alone (`release/1` removes it).
  defp settle(staging, entry, []) do
    case Cache.install(staging, entry) do
      :ok -> entry
      {:error, _} -> staging
    end
  end

  defp settle(staging, _entry, _lost), do: staging

  defp keep_scratch(facts, [], _staged), do: facts

  defp keep_scratch(facts, _lost, staged) do
    work = work_dir(facts)
    scratch = Path.join(work, "lost")
    File.write!(scratch, Enum.map_join(staged, "\n", &elem(&1, 2)))
    %{facts | work: work}
  end

  defp digest_files(dir) do
    for name <- File.ls!(dir), String.ends_with?(name, ".facts"), into: %{} do
      {:ok, digest} = Cache.file_digest(Path.join(dir, name))
      {name, digest}
    end
  end

  # Each relation file's source, the producers' files joined in order.
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
        paths = Enum.map(parts, &elem(&1, 1))
        {:ok, digest} = Cache.files_digest(paths)
        {name, {digest, paths}}
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
  relation file linked from the store, every schema relation without
  rows an empty file, as `Argus.Pipeline.run/3` leaves them.
  """
  @spec materialize(t()) :: {:ok, t()} | {:error, term()}
  def materialize(%__MODULE__{dir: dir} = facts) when is_binary(dir), do: {:ok, facts}

  def materialize(%__MODULE__{} = facts) do
    work = work_dir(facts)
    dir = Path.join(work, "facts")
    facts = %{facts | work: work}

    with :ok <- File.mkdir_p(dir),
         :ok <-
           Shards.assemble(Map.new(facts.relations, fn {n, {_d, p}} -> {n, p} end), dir, :link),
         :ok <- touch_empty(dir, facts.relations) do
      {:ok, %{facts | dir: dir}}
    end
  end

  defp touch_empty(dir, relations) do
    Enum.reduce_while(schema_files(), :ok, fn name, :ok ->
      if Map.has_key?(relations, name) do
        {:cont, :ok}
      else
        case File.write(Path.join(dir, name), "") do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:write_failed, name, reason}}}
        end
      end
    end)
  end

  defp work_dir(%__MODULE__{work: work}) when is_binary(work), do: work

  defp work_dir(%__MODULE__{store: store}) do
    work = Path.join([store, "work", "#{:os.getpid()}-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(work)
    work
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
          {:cont, {:ok, %{facts | relations: Map.put(facts.relations, name, {digest, [path]})}}}

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

  def release(%__MODULE__{work: work}) do
    case File.read(Path.join(work, "lost")) do
      {:ok, dirs} -> dirs |> String.split("\n", trim: true) |> Enum.each(&File.rm_rf/1)
      {:error, _} -> :ok
    end

    File.rm_rf(work)
    :ok
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
      :error -> if name in schema_files(), do: empty_digest(), else: "absent"
    end
  end

  @doc """
  The kept solve `rules_path` would be read from: `{:ok, entry}`, or
  why the program's inputs could not be resolved.
  """
  @spec entry(t(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def entry(%__MODULE__{} = facts, rules_path, opts) do
    with {:ok, bin} <- souffle_bin(opts),
         {:ok, inputs} <-
           Souffle.input_files(rules_path,
             souffle_bin: bin,
             programs: Cache.dir(facts.store, :programs)
           ) do
      digests = Enum.map(inputs, &{&1, digest(facts, &1)})
      solves = Cache.dir(facts.store, :solves)
      {:ok, Souffle.Cache.named(solves, facts.group, rules_path, bin, digests)}
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
  Solves `rules_path` over the facts, or reads the kept solve back:
  `{:ok, results, facts}` with the results as `Argus.Souffle.run/3`
  returns them, and the facts with any `.facts` file the program writes
  (a stage's) in place of what they held — in the directory too, when
  there is one. A miss solves over `facts.dir`, made first when there is
  none. Honors `:souffle_bin` and `:souffle_timeout`.
  """
  @spec solve(t(), Path.t(), keyword()) :: {:ok, Souffle.result(), t()} | {:error, term()}
  def solve(%__MODULE__{} = facts, rules_path, opts) do
    with {:ok, entry} <- entry(facts, rules_path, opts) do
      case Cache.fetch(entry) do
        {:ok, entry} ->
          with {:ok, results} <- Souffle.read_outputs(entry),
               {:ok, facts} <- put_outputs(facts, entry) do
            {:ok, results, facts}
          end

        :miss ->
          solve_and_keep(facts, entry, rules_path, opts)
      end
    end
  end

  # A directory made for this solve alone goes with a failure.
  defp solve_and_keep(facts, entry, rules_path, opts) do
    with {:ok, materialized} <- materialize(facts) do
      case solve_into(materialized, entry, rules_path, opts) do
        {:ok, _results, _facts} = ok ->
          ok

        {:error, _} = error ->
          if facts.work == nil, do: release(materialized)
          error
      end
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
  # facts by their content, and replace what the directory held.
  defp put_outputs(facts, entry) do
    with {:ok, digests} <- Souffle.Cache.manifest(entry) do
      outputs =
        for {name, digest} <- digests, String.ends_with?(name, ".facts"), do: {name, digest}

      Enum.reduce_while(outputs, {:ok, facts}, fn {name, digest}, {:ok, facts} ->
        path = Path.join(entry, name)
        facts = %{facts | relations: Map.put(facts.relations, name, {digest, [path]})}

        case place_output(facts.dir, path, name) do
          :ok -> {:cont, {:ok, facts}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp place_output(nil, _path, _name), do: :ok
  defp place_output(dir, path, name), do: Shards.place([path], Path.join(dir, name), :link)

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
