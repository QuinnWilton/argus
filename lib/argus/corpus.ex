defmodule Argus.Corpus do
  @moduledoc """
  Real-world checkouts as a regression corpus: a repository at the commit
  before a closed-issue fix, and at the fix, compiled once into a cache
  and analyzed in this VM.

  Every rule that came out of the 2026-09 issue-mining pass was verified
  this way — the finding is present on the pre-fix tree and absent on the
  fix — and `Argus.CorpusTest` keeps that true, as part of the ordinary
  test suite. `mix argus.corpus` uses the same module to fetch the trees
  ahead of time and to tally every title across them, which is the noise
  check after a rule changes.

  ## Layout

  `test/corpus/pairs.exs` lists the pairs. Checkouts live under
  `ARGUS_CORPUS_DIR` (default `~/.cache/argus/corpus`), one directory per
  `<repo>-<sha7>`, compiled in `MIX_ENV=dev` with the project's own
  dependencies; a marker file records a successful compile so a warm run
  never compiles again. Nothing is added to the project's dependency
  set: argus runs over its `ebin` from this VM.

  The facts extracted from a checkout are cached beside it, in
  `.argus-facts/<digest>/facts`, so a warm run costs only the solves.
  Extraction is most of the cost of a large tree and its inputs never
  move between runs: the digest covers the beams, the code and Datalog
  that extraction reaches (`engine_digest/0`), the runtime and the
  solver, so a change to any of them misses. None of it names the
  directory argus was built in, so every worktree of one commit shares
  the entries, and a stale entry is pruned when a fresh one is
  installed.

  The project's `elixir:` requirement is relaxed so an old tree builds on
  the current toolchain; a pair may name an `elixir:` version instead,
  exported as `ASDF_ELIXIR_VERSION` for the compile.
  """

  @type pair :: %{
          required(:repo) => String.t(),
          required(:issue) => String.t(),
          required(:pre) => String.t(),
          optional(:fix) => String.t(),
          optional(:elixir) => String.t(),
          optional(:subdir) => String.t(),
          optional(:module) => String.t(),
          required(:finding) => {atom(), String.t()}
        }

  @typedoc """
  One side of a pair on disk: `dir` is the clone, `project` the Mix
  project inside it — the same directory unless the pair names a
  `subdir:` (a repository whose `mix.exs` lives under `elixir/`, one app
  of an umbrella under `apps/`).
  """
  @type checkout :: %{name: String.t(), dir: String.t(), project: String.t(), sha: String.t()}

  @pairs_file Path.join([__DIR__, "..", "..", "test", "corpus", "pairs.exs"]) |> Path.expand()

  @doc "The issue pairs, from `test/corpus/pairs.exs`."
  @spec pairs() :: [pair()]
  def pairs do
    {pairs, _} = Code.eval_file(@pairs_file)
    pairs
  end

  @doc "Where checkouts live."
  @spec root() :: String.t()
  def root do
    case System.get_env("ARGUS_CORPUS_DIR") do
      nil -> Path.expand("~/.cache/argus/corpus")
      dir -> Path.expand(dir)
    end
  end

  @doc "The checkout for one side of a pair: `:pre` or `:fix`."
  @spec checkout(pair(), :pre | :fix) :: checkout() | nil
  def checkout(pair, side) do
    case Map.get(pair, side) do
      nil ->
        nil

      sha ->
        name = "#{Path.basename(pair.repo)}-#{String.slice(sha, 0, 7)}"
        dir = Path.join(root(), name)
        %{name: name, dir: dir, project: Path.join(dir, Map.get(pair, :subdir, ".")), sha: sha}
    end
  end

  @doc """
  Clones (if absent) and compiles (if not yet marked) one checkout.

  Returns the `.beam` files of the project's own application, or an
  error naming the step that failed and its log.
  """
  @spec ensure(pair(), :pre | :fix) :: {:ok, [Path.t()]} | {:error, String.t()}
  def ensure(pair, side) do
    with %{} = co <- checkout(pair, side) || {:error, "no #{side} side for #{pair.issue}"},
         :ok <- clone(pair, co),
         :ok <- compile(pair, co) do
      beams(co)
    end
  end

  @doc """
  Runs every analysis over one side of a pair; the findings as
  `Argus.run_analyses/2` returns them.

  Clones and compiles the checkout if needed (`ensure/2`), then solves
  over its cached facts, extracting them first only when no entry for
  the current `engine_digest/0` and beams exists.
  """
  @spec analyze(pair(), :pre | :fix) :: {:ok, Argus.Findings.t()} | {:error, term()}
  def analyze(pair, side) do
    with %{} = co <- checkout(pair, side) || {:error, "no #{side} side for #{pair.issue}"},
         {:ok, beams} <- ensure(pair, side),
         {:ok, facts_dir} <- facts(co, beams) do
      Argus.run_analyses(beams, analyses: :all, facts_dir: facts_dir)
    end
  end

  @doc """
  A digest of everything on argus's side that decides what facts a beam
  yields: the compiled code of `engine_modules/0` (`Argus.BeamDigest`,
  so a build in another worktree of the same code has the same digest
  and reuses the entries), what each analysis
  declares it extracts with, the Datalog stage 0 derives the call graph
  with, the OTP and Elixir the extraction runs on, the applications on
  the code path whose specs `Argus.Extractors.Specs` reads
  (`Argus.Specs.environment_digest/1`: their versions, and the beams of
  every dependency outside OTP and Elixir except argus's own), and the
  solver's version.
  Computed once per VM.

  Narrower than the whole of argus on purpose: a finding's prose, a
  rule, the corpus harness itself change without moving a fact, and a
  digest over all of them would re-extract every checkout on each edit.
  """
  @spec engine_digest() :: String.t()
  def engine_digest do
    key = {__MODULE__, :engine_digest}

    case :persistent_term.get(key, nil) do
      nil ->
        digest = compute_engine_digest()
        :persistent_term.put(key, digest)
        digest

      digest ->
        digest
    end
  end

  @doc "The `{analysis, title}` pairs among findings."
  @spec titles(map()) :: MapSet.t({atom(), String.t()})
  def titles(%{findings: findings}) do
    MapSet.new(findings, &{&1.analysis, &1.title})
  end

  @doc """
  Whether the pair's finding is among the results: its analysis and title,
  and — when the pair names a `module:` — anchored in that module. The
  module matters on the fix side: the same title can be true of another
  module in the tree (db_connection has two foreign starters; the fix
  removed one).
  """
  @spec present?(map(), pair()) :: boolean()
  def present?(%{findings: findings}, pair) do
    {analysis, title} = pair.finding
    module = Map.get(pair, :module)

    Enum.any?(findings, fn f ->
      f.analysis == analysis and f.title == title and
        (module == nil or inspect(f.module) == module)
    end)
  end

  # ── Facts cache ───────────────────────────────────────────────────────

  @facts_cache ".argus-facts"

  # A hit touches its entry: what `prune_facts/2` reads to tell an entry
  # a VM beside this one is using from one nobody will use again.
  defp facts(co, beams) do
    digest = facts_digest(beams)
    entry = Path.join([co.dir, @facts_cache, digest])
    facts_dir = Path.join(entry, "facts")

    if File.dir?(facts_dir) do
      File.touch(entry)
      {:ok, facts_dir}
    else
      extract_into_cache(co, digest, beams)
    end
  end

  # Extracted where `extract_facts/3` puts it, copied into a staging
  # directory beside the entry and renamed into place: the entry is
  # complete or absent, never half-written. Another VM installing the
  # same digest first wins the rename, and its entry is the one used.
  defp extract_into_cache(co, digest, beams) do
    {:ok, analyses} = Argus.Analysis.set(:all)

    with {:ok, fresh} <- Argus.Analysis.extract_facts(beams, analyses) do
      cache = Path.join(co.dir, @facts_cache)
      entry = Path.join(cache, digest)

      staging =
        Path.join(cache, "#{digest}.#{:os.getpid()}.#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(staging)
        File.cp_r!(fresh, Path.join(staging, "facts"))

        case File.rename(staging, entry) do
          :ok -> prune_facts(cache, digest)
          {:error, reason} when reason in [:eexist, :enotempty, :eisdir] -> File.rm_rf!(staging)
        end

        {:ok, Path.join(entry, "facts")}
      after
        File.rm_rf(Path.dirname(fresh))
        File.rm_rf(staging)
      end
    end
  end

  @stale_after_seconds 60 * 60

  @doc """
  Removes the entries of a checkout's facts cache other than `keep` that
  no run has touched for an hour.

  An entry under another digest was extracted by an argus, a solver or
  a build that is gone — or by a VM running beside this one on other
  code. A hit touches its entry, so one in use is never older than
  the run using it, and removing it from under that run left its
  solves with no facts to read. Only installed entries are candidates,
  never a staging directory another VM may still be filling.
  """
  @spec prune_facts(Path.t(), String.t()) :: :ok
  def prune_facts(cache, keep) do
    now = System.os_time(:second)

    for entry <- File.ls!(cache),
        entry != keep,
        Regex.match?(~r/^[0-9a-f]{64}$/, entry),
        path = Path.join(cache, entry),
        {:ok, %File.Stat{mtime: touched}} <- [File.stat(path, time: :posix)],
        now - touched > @stale_after_seconds,
        do: File.rm_rf!(path)

    :ok
  end

  defp facts_digest(beams) do
    beams
    |> Enum.sort_by(&Path.basename/1)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn beam, hash ->
      hash
      |> :crypto.hash_update(Path.basename(beam))
      |> :crypto.hash_update(File.read!(beam))
    end)
    |> :crypto.hash_update(engine_digest())
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  The modules whose code the facts depend on: every module a remote
  call reaches from the extraction's entry points — `Argus.Analysis`,
  `Argus.Pipeline`, every `Argus.Extractors` module and every extractor
  an analysis declares — through this project and its dependencies
  (beam_spy's disassembly, ctf's literals), stopping at OTP and Elixir,
  whose versions the digest carries instead. Dynamic dispatch is not a
  remote call, which is why the extractors are roots and not merely
  reached; the analyses that name them are not in the set, only their
  declarations are, as data.
  """
  @spec engine_modules() :: [module()]
  def engine_modules do
    extractors_declared =
      Enum.flat_map(Argus.Analysis.builtin_analysis_modules(), & &1.extractors())

    extractors_shipped =
      for mod <- Application.spec(:panoptes, :modules),
          String.starts_with?(Atom.to_string(mod), "Elixir.Argus.Extractors."),
          do: mod

    roots = [Argus.Analysis, Argus.Pipeline] ++ extractors_declared ++ extractors_shipped

    roots
    |> reachable(%{})
    |> Enum.sort()
  end

  defp reachable([], seen), do: Map.keys(seen)

  defp reachable([mod | rest], seen) do
    if Map.has_key?(seen, mod) or not digested?(mod) do
      reachable(rest, seen)
    else
      {:ok, {^mod, [imports: imports]}} =
        :beam_lib.chunks(String.to_charlist(beam_of(mod)), [:imports])

      called = for {callee, _fun, _arity} <- imports, uniq: true, do: callee
      reachable(called ++ rest, Map.put(seen, mod, true))
    end
  end

  # A module of this project or a dependency; OTP's and Elixir's own are
  # covered by their versions, and a consolidated protocol is the build's
  # dispatch table, not code that shapes a fact.
  defp digested?(mod) do
    case :code.which(mod) do
      path when is_list(path) ->
        path = List.to_string(path)

        not String.starts_with?(path, List.to_string(:code.root_dir())) and
          not String.starts_with?(path, elixir_root()) and
          "consolidated" not in Path.split(path)

      _not_a_file ->
        false
    end
  end

  defp elixir_root, do: :elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()

  defp beam_of(mod), do: mod |> :code.which() |> List.to_string()

  defp compute_engine_digest do
    declarations =
      Argus.Analysis.builtin_analysis_modules()
      |> Enum.map(&{&1.name(), &1.extractors()})
      |> Enum.sort()

    {:ok, all} = Argus.Analysis.set(:all)

    engine_modules()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn mod, hash ->
      {:ok, code} = Argus.BeamDigest.digest(beam_of(mod))

      hash
      |> :crypto.hash_update(Atom.to_string(mod))
      |> :crypto.hash_update(code)
    end)
    |> :crypto.hash_update(:erlang.term_to_binary({declarations, Enum.sort(all)}))
    |> then(fn hash ->
      Enum.reduce(stage0_programs(), hash, fn file, hash ->
        hash
        |> :crypto.hash_update(Path.basename(file))
        |> :crypto.hash_update(File.read!(file))
      end)
    end)
    |> :crypto.hash_update(System.version())
    |> :crypto.hash_update(System.otp_release())
    |> :crypto.hash_update(:erlang.system_info(:version) |> List.to_string())
    |> :crypto.hash_update(souffle_version())
    # Argus's own beams are left out: `engine_modules/0` above already
    # names the ones extraction reaches, and the rest (prose, rules, this
    # harness, the test fixtures) must not move the key.
    |> :crypto.hash_update(Argus.Specs.environment_digest(exclude: [:panoptes]))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Stage 0 and everything it includes, transitively, resolved the way
  # Souffle resolves an include: relative to the including file.
  defp stage0_programs do
    walk_includes([Argus.Analysis.stage0_rules_path()], [])
  end

  defp walk_includes([], seen), do: Enum.reverse(seen)

  defp walk_includes([file | rest], seen) do
    if file in seen do
      walk_includes(rest, seen)
    else
      included =
        ~r/^\.include\s+"([^"]+)"/m
        |> Regex.scan(File.read!(file))
        |> Enum.map(fn [_, rel] -> Path.expand(rel, Path.dirname(file)) end)

      walk_includes(included ++ rest, [file | seen])
    end
  end

  defp souffle_version do
    case System.find_executable("souffle") do
      nil ->
        "no souffle"

      bin ->
        {out, _status} = System.cmd(bin, ["--version"], stderr_to_stdout: true)
        out
    end
  end

  # ── Steps ─────────────────────────────────────────────────────────────

  defp clone(pair, %{dir: dir, sha: sha} = co) do
    if File.dir?(dir) do
      :ok
    else
      File.mkdir_p!(root())
      url = "https://github.com/#{pair.repo}.git"

      with :ok <- run(["git", "clone", "-q", url, dir], root(), [], "clone #{pair.repo}"),
           :ok <- run(["git", "checkout", "-q", sha], dir, [], "checkout #{sha}") do
        relax_elixir_requirement(co.project)
      end
    end
  end

  # The project's `elixir:` requirement says what it was tested on, not
  # what it needs; an old tree usually builds on the current toolchain.
  # A pair whose tree does not names an `elixir:` version instead.
  defp relax_elixir_requirement(dir) do
    mix_exs = Path.join(dir, "mix.exs")
    source = File.read!(mix_exs)
    relaxed = Regex.replace(~r/elixir:\s*"[^"]*"/, source, ~s(elixir: "~> 1.18"), global: false)
    if relaxed != source, do: File.write!(mix_exs, relaxed)
    :ok
  end

  defp compile(pair, %{dir: dir, sha: sha} = co) do
    marker = Path.join(dir, ".argus-compiled-#{String.slice(sha, 0, 7)}")

    if File.exists?(marker) do
      :ok
    else
      env = compile_env(pair)

      with :ok <- build(co.project, env, co.name) do
        File.write!(marker, "")
        :ok
      end
    end
  end

  # As locked first; if a locked dependency no longer compiles on this
  # toolchain (an old ecto redefining a built-in type), once more with
  # the dependencies unlocked to their latest compatible releases. The
  # project's own code is what is analyzed, and it is the same either way.
  defp build(dir, env, name) do
    with :ok <- run(["mix", "deps.get"], dir, env, "deps.get for #{name}"),
         {:error, first} <- run(["mix", "compile"], dir, env, "compile #{name}"),
         :ok <- run(["mix", "deps.unlock", "--all"], dir, env, "deps.unlock for #{name}"),
         :ok <- run(["mix", "deps.get"], dir, env, "deps.get (unlocked) for #{name}"),
         {:error, second} <- run(["mix", "compile"], dir, env, "compile (unlocked) #{name}") do
      {:error, first <> "\n\nand with dependencies unlocked:\n" <> second}
    else
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  # A clean environment for the child mix: the parent runs in MIX_ENV=test
  # with its own build paths, none of which the checkout must inherit.
  defp compile_env(pair) do
    base = [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}, {"MIX_EXS", nil}]

    case Map.get(pair, :elixir) do
      nil -> base
      version -> [{"ASDF_ELIXIR_VERSION", version} | base]
    end
  end

  # An umbrella app builds into the umbrella's _build; the glob starts at
  # the project and climbs to the clone. Without a subdir the two are the
  # same directory, and a checkout may hold more than one build — each
  # beam counts once, from one build, or every call-site count doubles.
  defp beams(%{project: project, dir: dir, name: name}) do
    app = app_name(project)

    found =
      Enum.uniq(
        Path.wildcard(Path.join([project, "_build", "*", "lib", app, "ebin", "*.beam"])) ++
          Path.wildcard(Path.join([dir, "_build", "*", "lib", app, "ebin", "*.beam"]))
      )

    case found |> Enum.group_by(&build_of/1) |> Map.values() |> Enum.sort_by(&build_rank/1) do
      [] -> {:error, "no beams for #{name} (app #{app})"}
      [beams | _others] -> {:ok, beams}
    end
  end

  defp build_of(beam), do: beam |> Path.split() |> Enum.take_while(&(&1 != "lib")) |> Path.join()

  # The build the corpus compiles is dev; another one present in the tree
  # is a leftover, and a bigger one is not a better one.
  defp build_rank([beam | _] = beams) do
    {if(String.contains?(beam, "/_build/dev/"), do: 0, else: 1), -length(beams)}
  end

  defp app_name(dir) do
    source = File.read!(Path.join(dir, "mix.exs"))

    case Regex.run(~r/app:\s*:(\w+)/, source) do
      [_, app] -> app
      nil -> raise "no app: in #{dir}/mix.exs"
    end
  end

  defp run([cmd | args], cwd, env, step) do
    case System.cmd(cmd, args, cd: cwd, env: env, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "#{step} failed (exit #{status}):\n#{tail(out)}"}
    end
  end

  defp tail(out) do
    out |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")
  end
end
