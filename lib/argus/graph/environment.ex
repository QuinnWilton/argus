defmodule Argus.Graph.Environment do
  @moduledoc """
  What the memoized graph is a function of beyond the beams, stamped by
  the driver into inputs.

  - `:env_fingerprint` (`env/2`) — what every query runs on: the Elixir
    and OTP versions, scry's own code (`code_digest/2`; a path
    dependency moves its code without moving its version), and the
    applications on the code path
    (`Argus.Specs.environment_digest/1`), whose specs extraction reads
    for every remote callee — by version, and by beams for a dependency
    outside OTP and Elixir, less argus's own and the applications the
    scan watches (a read of one of those is tracked where it happens,
    by `Argus.Graph`). Moving it re-extracts every module and re-runs
    every solve.
  - `:extraction_code` (`extraction_code/0`) — the code argus's fact
    producers run: the base (`Argus.Pipeline`'s emitter and the
    derivations every extraction makes) and each extractor scry runs,
    as `Argus.Cache.Code` walks it, joined into one digest — without
    argus's schema modules, which are data: a query depends on the
    entries of the schema it read (`Argus.Graph`'s `schema_read`), so
    a schema edit re-extracts only the modules whose rows read what it
    changed. Argus ships extractor changes without moving its
    version or schema (and a path dependency never moves its version at
    all), so the version alone let a warm manifest serve rows the
    current code would not compute. Moving it re-extracts every module,
    and nothing above a module whose rows came out equal runs. An argus
    edit it does not reach — the findings' prose, the analyses modules,
    the Souffle wrapper, argus's caches, its corpus harness — extracts
    nothing.
  - `:argus_code` (`argus_code/1`) — every argus beam, debug info
    included: what the findings are built by (the analyses' prose,
    their identity rules), and where a program that calls argus has its
    specs read from. Rebuilding the findings is cheap, so any argus edit
    does.
  - `:rules_digest` (`rules/2`) — per analysis (and per shared stage's
    program: `:stage0`, `:points_to`, `:points_to_bounded`), the Datalog
    it runs as its solve loads it: its rules
    file and everything that file `.include`s, transitively, but of
    argus's generated declaration files only the declarations of the
    relations the program loads (`program_digest/2`), plus the solver's
    version. A rule edit moves only the digests of the analyses whose
    programs contain the edited file, and a schema edit only those of
    the programs that load a relation whose declaration it changed, so
    exactly those re-solve, and nothing is re-extracted. How argus runs
    the solver and reads its output back is keyed the way argus's own
    solve store keys it: by the program and the solver, not by argus's
    code.

  Anything else that changes an extraction or a solve without changing
  a beam must move a value here, or a warm manifest serves results the
  current toolchain would not compute.
  """

  @typedoc "The `:env_fingerprint` input's value."
  @type env :: %{
          elixir: String.t(),
          otp: String.t(),
          scry: String.t(),
          scry_code: String.t(),
          specs_environment: String.t()
        }

  @typedoc """
  A `:rules_digest` key: an analysis, or a shared stage's program (`:stage0`,
  `:points_to`, `:points_to_bounded`).
  """
  @type rules_key :: atom()

  @doc """
  The environment fingerprint: runtime versions, a digest of scry's
  code, and a digest of the applications on the code path — except argus's own (`argus_code/1` keys a read of its
  specs) and `watched`, the applications whose beams the scan reads
  itself (the project, and its dependencies with `include_deps`). Their
  beams move with every edit, and the graph already tracks each one: an
  analyzed module as a `:beam_meta` input, an ignored one as an
  `:ignored_beam` input its callers depend on. Each excluded application
  is still named, by version.

  Hashing every dependency's beams is most of what this costs (about a
  second on a project with a hundred dependencies), so with `:cache`
  argus keeps each ebin's hashes on disk under a stamp of its beams'
  stats — name, modification time, size and inode — and a fresh VM
  stats the beams instead of reading them. A beam written within the
  last two seconds is read every time. One rewritten in place with
  other code of the same size and its modification time set back (as
  `touch -r` does) keeps its old hashes, as scry's own scan keeps a
  beam of the same size and modification time; `refresh: true` is the
  way out.

  ## Options

    * `:cache` — the store (`Argus.Cache`'s layout) to keep the hashes
      in, under its `ebins/`; nil, or stores turned off with
      `ARGUS_NO_CACHE`, keeps them in this VM alone.
    * `:refresh` — drop what the store kept before computing, so every
      ebin this VM has not hashed yet is hashed again and kept afresh
      (`--force`). What this VM already holds stands: a fresh VM
      computes all of it.
  """
  @spec env([atom()], keyword()) :: env()
  def env(watched \\ [], opts \\ []) do
    %{
      elixir: System.version(),
      otp: System.otp_release(),
      scry: app_vsn(:scry),
      scry_code: app_code_digest(:scry),
      # Extraction reads remote callees' specs off the code path; this
      # names every application there by version, and a dependency
      # outside OTP and Elixir also by its beams (a path dependency moves
      # its code without moving its version).
      specs_environment:
        Argus.Specs.environment_digest(
          [exclude: Enum.uniq([:panoptes | watched])] ++ ebins_cache(opts)
        )
    }
  end

  defp ebins_cache(opts) do
    with [cache: ebins] <- ebins_store(opts) do
      if Keyword.get(opts, :refresh, false), do: File.rm_rf(ebins)
      [cache: ebins]
    end
  end

  # `[cache: dir]`, the store's `ebins/`, or none.
  defp ebins_store(opts) do
    case Argus.Cache.store(cache: Keyword.get(opts, :cache)) do
      nil -> []
      store -> [cache: Argus.Cache.dir(store, :ebins)]
    end
  end

  @doc """
  A digest of the code argus's fact producers run (`extraction_closure/0`),
  each module by name and by what its code does (`Argus.BeamDigest`,
  without debug info), together with the producers themselves: an
  extractor that starts or stops running moves it too. A closure argus
  cannot key (a module with no beam on disk: compiled in memory, or
  cover-compiled) falls back to every argus beam, as a whole.
  """
  @spec extraction_code() :: String.t()
  def extraction_code do
    case extraction_closure() do
      {:ok, modules} ->
        parts =
          modules
          |> Task.async_stream(
            fn
              {module, :absent} -> {module, :absent}
              {module, beam} -> {module, beam_digest(beam, [])}
            end,
            ordered: true,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, part} -> part end)

        digest({producers(), parts})

      {:error, _no_beam} ->
        "argus:" <> argus_code()
    end
  end

  @doc """
  The modules argus's fact producers run, sorted, each with the beam it
  runs from, or `:absent` (a module called on the way that is not on the
  code path): the union of `Argus.Cache.Code.closure/2` over the base
  and every extractor scry runs (`Argus.Graph.all_extractors/0`),
  with `schema: :recorded` — `Argus.Schema` and its concern modules
  walked through but left out. They are data, every accessor of theirs
  records the entry it returns, and each query that reads them depends
  on the entries it read instead.
  """
  @spec extraction_closure() ::
          {:ok, [{module(), Path.t() | :absent}]} | {:error, {:no_beam, module()}}
  def extraction_closure do
    Enum.reduce_while(producers(), {:ok, %{}}, fn producer, {:ok, acc} ->
      case Argus.Cache.Code.closure(producer, schema: :recorded) do
        {:ok, modules} -> {:cont, {:ok, Map.merge(acc, Map.new(modules))}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.sort(modules)}
      {:error, _} = error -> error
    end
  end

  defp producers, do: [:base | Argus.Graph.all_extractors()]

  @doc """
  A digest of every argus beam, debug info (where specs are read from)
  included: moves with any argus edit.

  Each beam is digested as `Argus.Specs.ebin_digests/2` keeps it: under
  a stamp of the ebin's beams' stats, in the VM and — with `:cache` —
  in the store's `ebins/`, beside the dependencies' hashes the
  environment digest keeps there (`env/2`, whose `refresh:` drops
  them), so a fresh VM stats argus's beams instead of reading each one.
  A beam written within the last two seconds is read every time.

  ## Options

    * `:cache` — the store (`Argus.Cache`'s layout), or nil.
  """
  @spec argus_code(keyword()) :: String.t()
  def argus_code(opts \\ []) do
    case :code.lib_dir(:panoptes) do
      {:error, _} ->
        "unknown"

      dir ->
        ebin = Path.join(to_string(dir), "ebin")
        %{^ebin => beams} = Argus.Specs.ebin_digests([ebin], ebins_store(opts))
        digest(beams)
    end
  end

  # Moves every kept set of rules digests: bump it when how one is
  # computed changes.
  @rules_format "scry-rules-1"

  @doc """
  The rules digest of each of `analyses`, and of `:stage0`,
  `:points_to` and `:points_to_bounded` (the shared call graph's
  program, and the process points-to stage's two: argus runs the
  bounded one in place of the exact one when the exact fixpoint
  outgrows its budget, so an edit to either can move what the stage
  stages): the solver's version
  (`Argus.Souffle.Cache.version/2`) and the program as a solve of it
  loads it (`program_digest/2`). Keyed as argus keys a solve, less the
  facts: a rule edit moves the programs that include the edited file,
  a schema edit the programs that load a relation whose declaration it
  changed, and a relation added to the schema, a version bump or an
  edit to a relation's prose moves none.

  With a store, a warm run computes none of it. The digests are a
  function of argus's Datalog tree (`priv/dl`, every program's files
  among them) and the solver, so they are kept in the store's
  `programs/` under a digest of every file of the tree's content and
  the solver's version — reading 50 small files where the declared
  digests parse each program's files anew in every VM — as are what
  each program loads and the solver's version itself (under a stamp of
  its binary), which the digests are computed from on a miss. A program
  that includes a file outside the tree is computed every run.

  ## Options

    * `:cache` — the store (`Argus.Cache`'s layout); nil, or stores
      turned off with `ARGUS_NO_CACHE`, computes every digest and asks
      the solver once per VM.
    * `:refresh` — drop what `programs/` kept first (`--force`), so the
      solver is asked again: a stamp names the binary's file, not what
      it runs.
  """
  @spec rules([atom()], keyword()) :: %{optional(rules_key()) => String.t()}
  def rules(analyses, opts \\ []) do
    bin = Argus.Souffle.executable()
    store = programs_store(opts)
    solver = if bin, do: Argus.Souffle.Cache.version(bin, store), else: "unknown"

    programs =
      [
        {:stage0, Argus.Analysis.stage0_rules_path()},
        {:points_to, Argus.Analysis.points_to_rules_path()},
        {:points_to_bounded, Argus.Analysis.points_to_bounded_rules_path()}
      ] ++
        for analysis <- analyses, {:ok, path} <- [rules_path(analysis)], do: {analysis, path}

    compute = fn -> compute_rules(programs, solver, souffle_bin: bin, programs: store) end

    with dir when is_binary(dir) <- store,
         {:ok, tree} <- tree_digest(programs) do
      key = Argus.Cache.key([@rules_format, solver, bin || "", tree | program_names(programs)])
      kept_rules(Path.join(dir, "rules-" <> key), programs, compute)
    else
      _ -> compute.()
    end
  end

  # Side by side: each program's files are read and parsed afresh, and a
  # program the store does not hold yet asks the solver what it loads
  # (every program, after a schema edit).
  defp compute_rules(programs, solver, program_opts) do
    programs
    |> Task.async_stream(
      fn {key, path} -> {key, digest({solver, program_digest(path, program_opts)})} end,
      ordered: false,
      timeout: :infinity
    )
    |> Map.new(fn {:ok, entry} -> entry end)
  end

  defp program_names(programs) do
    root = dl_root()

    Enum.flat_map(Enum.sort(programs), fn {key, path} ->
      [Atom.to_string(key), Path.relative_to(path, root)]
    end)
  end

  defp dl_root, do: Path.join(to_string(:code.priv_dir(:panoptes)), "dl")

  # Every file of argus's Datalog tree, by name under it and content:
  # what each program is, whatever it includes within the tree.
  defp tree_digest(programs) do
    root = dl_root()

    if Enum.all?(programs, fn {_key, path} -> under?(path, root) end) do
      root
      |> Path.join("**/*.dl")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn file, {:ok, parts} ->
        case File.read(file) do
          {:ok, content} ->
            {:cont, {:ok, [Path.relative_to(file, root), :crypto.hash(:sha256, content) | parts]}}

          {:error, _} ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, parts} -> {:ok, Argus.Cache.key(parts)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp under?(path, root), do: String.starts_with?(Path.expand(path), root <> "/")

  # The digests kept at `entry`, or computed and kept there when every
  # program's files lie within the tree its key names.
  defp kept_rules(entry, programs, compute) do
    with {:ok, entry} <- Argus.Cache.fetch(entry),
         {:ok, bytes} <- File.read(entry),
         {:ok, %{} = digests} <- safe_decode(bytes),
         true <- Enum.all?(programs, fn {key, _path} -> is_map_key(digests, key) end) do
      digests
    else
      _missing ->
        digests = compute.()
        if within_tree?(programs), do: keep(entry, digests)
        digests
    end
  end

  defp within_tree?(programs) do
    root = dl_root()

    Enum.all?(programs, fn {_key, path} ->
      path
      |> Argus.Souffle.Cache.program_files()
      |> Enum.all?(fn {_spelled, file} -> under?(file, root) end)
    end)
  rescue
    File.Error -> false
  end

  # A store that cannot be written to is computed around, not failed on.
  defp keep(entry, digests) do
    staging = "#{entry}.#{:os.getpid()}.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(entry)),
         :ok <- File.write(staging, :erlang.term_to_binary(digests)),
         :ok <- Argus.Cache.install(staging, entry) do
      :ok
    else
      _ -> File.rm(staging)
    end
  end

  defp safe_decode(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    ArgumentError -> :error
  end

  # The store's `programs/`, emptied first on a refresh; nil for none.
  defp programs_store(opts) do
    case Argus.Cache.store(cache: Keyword.get(opts, :cache)) do
      nil ->
        nil

      store ->
        programs = Argus.Cache.dir(store, :programs)
        if Keyword.get(opts, :refresh, false), do: File.rm_rf(programs)
        programs
    end
  end

  @doc """
  A digest of the Datalog program rooted at `path` as a solve of it
  loads it (`Argus.Souffle.Cache.declared_digest/2`): the file and every
  file it `.include`s, transitively, by the name the program spells and
  content — except that a file of declarations alone (argus's generated
  `base.dl`, `layer2.dl`, `priors.dl`) counts only by the declarations
  of the relations the program loads (`Argus.Souffle.input_relations/2`),
  and not by its comments. Souffle prunes every other input before it
  loads anything. When what the program loads cannot be resolved (no
  solver, or a program the solver rejects), every declaration counts;
  a program with a file missing digests as unreadable, and moves when
  the file appears.

  Options: `:souffle_bin` (the solver to resolve the loaded relations
  with, found on `PATH` by default) and `:programs` (a store's
  `programs/`, where they are kept across VMs).
  """
  @spec program_digest(Path.t(), keyword()) :: String.t()
  def program_digest(path, opts \\ []) do
    relations =
      case Argus.Souffle.input_relations(path, Keyword.take(opts, [:souffle_bin, :programs])) do
        {:ok, relations} -> relations
        {:error, _} -> :all
      end

    path
    |> Argus.Souffle.Cache.declared_digest(relations)
    |> Base.encode16(case: :lower)
  rescue
    # A file of the program is missing: no solve of it can run, and the
    # digest moves when the file appears.
    error in File.Error -> digest({:unreadable, Path.relative_to(error.path, Path.dirname(path))})
  end

  defp rules_path(analysis) do
    case Argus.Analysis.fetch_module(analysis) do
      {:ok, module} ->
        {:ok, Path.join([to_string(:code.priv_dir(:panoptes)), "dl", module.rules_file()])}

      :error ->
        :error
    end
  end

  @doc """
  A digest of every `.beam` in `ebin`, by name and by what its code
  does (`Argus.BeamDigest`: every chunk but the compile info, the docs
  and the Elixir type checker's export table, with the build root taken
  out; with `debug_info: true`, the debug info too). A rebuild of the
  same code digests the same, in any checkout: the type checker's table
  can come out different when the same source is compiled again beside
  other code, and would otherwise move the digest with nothing changed.
  A file `Argus.BeamDigest` cannot read is digested by its bytes.
  """
  @spec code_digest(Path.t(), [Argus.BeamDigest.option()]) :: String.t()
  def code_digest(ebin, opts \\ []) do
    ebin
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.sort()
    |> Task.async_stream(&{Path.basename(&1), beam_digest(&1, opts)},
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, part} -> part end)
    |> digest()
  end

  defp beam_digest(beam, opts) do
    case Argus.BeamDigest.digest(beam, opts) do
      {:ok, digest} -> digest
      {:error, _unreadable} -> {:bytes, File.read(beam)}
    end
  end

  defp app_code_digest(app, opts \\ []) do
    case :code.lib_dir(app) do
      {:error, _} -> "unknown"
      dir -> code_digest(Path.join(to_string(dir), "ebin"), opts)
    end
  end

  defp app_vsn(app) do
    _ = Application.load(app)

    case Application.spec(app, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  The version of the `souffle` on `PATH`, with its word size
  (`"2.5 (64-bit words)"`), or `"unknown"` when it cannot be run.
  """
  @deprecated "The rules digest names the solver by Argus.Souffle.Cache.version/2"
  @spec souffle_version() :: String.t()
  def souffle_version do
    case System.cmd("souffle", ["--version"], stderr_to_stdout: true) do
      {out, 0} -> parse_souffle_version(out)
      _ -> "unknown"
    end
  rescue
    # The binary disappeared between the availability check and here.
    ErlangError -> "unknown"
  end

  # The banner opens with a rule of dashes; the version and the word size
  # (32- and 64-bit builds disagree about numbers) are the lines that
  # matter. A banner without a version line is fingerprinted whole, so an
  # unfamiliar solver still moves the value when it changes.
  defp parse_souffle_version(banner) do
    case Regex.run(~r/^Version:\s*(\S+)/m, banner) do
      [_, version] ->
        case Regex.run(~r/^Word size:\s*(\d+)/m, banner) do
          [_, bits] -> "#{version} (#{bits}-bit words)"
          nil -> version
        end

      nil ->
        "unrecognized:" <> Base.encode16(:erlang.md5(banner), case: :lower)
    end
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
  end
end
