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

  Each checkout keeps a store beside it, `.argus-facts` (`Argus.Cache`):
  every producer's facts as a shard and every solve, keyed by content
  (`analyze/2`). A warm run extracts nothing and solves nothing; after
  an edit to one extractor only that extractor's shard is extracted
  again, after an edit to a rule only the programs it reaches solve
  again, and a solve whose inputs came out byte-identical is read back.
  None of the keys names the directory argus was built in, so every
  worktree of one commit shares the entries. An analysis prunes its
  checkout's store (`stale_facts/2`), sparing within each producer and
  program the few most recently used — the baseline of a
  before-and-after comparison among them — and `mix argus.corpus prune`
  does so across every checkout. Entries an older argus kept whole
  (`<digest>/facts` with its `solves/`) are never read, and go by the
  same policy.

  `analyze_all/2` runs checkouts `jobs/0` at a time; the test gate and
  `mix argus.corpus tally` both go through it.

  The project's `elixir:` requirement is relaxed so an old tree builds on
  the current toolchain; a pair may name an `elixir:` version instead,
  exported as `ASDF_ELIXIR_VERSION` for the compile, and an `otp:`
  version, whose asdf install's `bin` leads the compile's `PATH` (a
  locked Erlang dependency that no longer builds on OTP 28, like an old
  rabbit_common's `'street-address'` macro). The two go together: an
  Elixir built for OTP 28 does not load on 27.

  A monorepo that builds many apps from its root names the one analyzed
  with `app:`, and the variables its build reads with `env:` (EMQX
  compiles with `PROFILE` and `MIX_ENV` set to `emqx-enterprise`, and
  without its QUIC, RocksDB and jq NIFs). `env:` overrides the clean
  environment's `MIX_ENV`; the beams are taken from whichever build
  holds the app.

  A tree that vendors a dependency as a git submodule names
  `submodules: true`: the checkout initializes them at the commits the
  tree records before it compiles.
  """

  @type pair :: %{
          required(:repo) => String.t(),
          required(:issue) => String.t(),
          required(:pre) => String.t(),
          optional(:fix) => String.t(),
          optional(:elixir) => String.t(),
          optional(:otp) => String.t(),
          optional(:subdir) => String.t(),
          optional(:app) => String.t(),
          optional(:env) => %{optional(String.t()) => String.t()},
          optional(:submodules) => boolean(),
          optional(:module) => String.t(),
          required(:finding) => {atom(), String.t()}
        }

  @typedoc """
  One side of a pair on disk: `dir` is the clone, `project` the Mix
  project inside it — the same directory unless the pair names a
  `subdir:` (a repository whose `mix.exs` lives under `elixir/`, one app
  of an umbrella under `apps/`) — and `app` the app analyzed when the
  pair names one, else the project's own.
  """
  @type checkout :: %{
          name: String.t(),
          dir: String.t(),
          project: String.t(),
          sha: String.t(),
          app: String.t() | nil
        }

  # Each checkout's store, beside it.
  @facts_cache ".argus-facts"

  # Beside the facts in each facts cache entry: `analyze/2`'s kept solves.
  @solves "solves"

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

        %{
          name: name,
          dir: dir,
          project: Path.join(dir, Map.get(pair, :subdir, ".")),
          sha: sha,
          app: Map.get(pair, :app)
        }
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

  Clones and compiles the checkout if needed (`ensure/2`), then runs
  through the checkout's store (`cache:`, `Argus.Cache`): the facts are
  read from its shards, extracting only the producers no entry holds
  for the current code, and each solve is read back when what it reads
  is unchanged. Under `ARGUS_NO_CACHE` everything is extracted and
  solved afresh. The store is pruned afterwards (`prune_facts/2`).
  """
  @spec analyze(pair(), :pre | :fix) :: {:ok, Argus.Findings.t()} | {:error, term()}
  def analyze(pair, side) do
    with %{} = co <- checkout(pair, side) || {:error, "no #{side} side for #{pair.issue}"},
         {:ok, beams} <- ensure(pair, side) do
      store = store(co)

      try do
        Argus.run_analyses(beams, analyses: :all, cache: store)
      after
        if Argus.Cache.enabled?(), do: prune_facts(store)
      end
    end
  end

  @doc "A checkout's store (`Argus.Cache`): `<checkout>/.argus-facts`."
  @spec store(checkout()) :: Path.t()
  def store(%{dir: dir}), do: Path.join(dir, @facts_cache)

  @doc """
  How many checkouts `analyze_all/2` runs at once: `ARGUS_CORPUS_JOBS`,
  or 4 (at most the scheduler count). Each is extraction at scheduler
  width on a cold cache and up to four solves on a warm one, so more
  than a few only contend.
  """
  @spec jobs() :: pos_integer()
  def jobs do
    case System.get_env("ARGUS_CORPUS_JOBS") do
      nil ->
        min(4, System.schedulers_online())

      value ->
        case Integer.parse(String.trim(value)) do
          {jobs, ""} when jobs > 0 ->
            jobs

          _ ->
            raise ArgumentError,
                  "ARGUS_CORPUS_JOBS must be a positive integer, got: #{inspect(value)}"
        end
    end
  end

  @doc """
  The distinct checkouts the pairs need, as `{checkout, pair, side}` in
  pair order: a tree shared by several pairs appears once, under the
  first pair naming it.
  """
  @spec checkouts([pair()]) :: [{checkout(), pair(), :pre | :fix}]
  def checkouts(pairs) do
    for(
      pair <- pairs,
      side <- [:pre, :fix],
      co = checkout(pair, side),
      co != nil,
      do: {co, pair, side}
    )
    |> Enum.uniq_by(fn {co, _pair, _side} -> co.name end)
  end

  @doc """
  `analyze/2` over each of `checkouts` (as `checkouts/1` returns them),
  `jobs/0` at a time; `{checkout, reduce.(result)}` in input order.

  `reduce` runs in the task that analyzed the checkout, so only what it
  keeps crosses back: the findings of a large tree are megabytes of
  prose a caller rarely wants whole.
  """
  @spec analyze_all(
          [{checkout(), pair(), :pre | :fix}],
          ({:ok, Argus.Findings.t()} | {:error, term()} -> result)
        ) :: [{checkout(), result}]
        when result: term()
  def analyze_all(checkouts, reduce \\ & &1) do
    # Unordered, then sorted back: a large tree finishing late holds up
    # no other checkout's slot.
    checkouts
    |> Enum.with_index()
    |> Task.async_stream(
      fn {{co, pair, side}, index} -> {index, co, reduce.(analyze(pair, side))} end,
      max_concurrency: jobs(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, entry} -> entry end)
    |> Enum.sort_by(fn {index, _co, _result} -> index end)
    |> Enum.map(fn {_index, co, result} -> {co, result} end)
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

  @typedoc """
  What `stale_facts/2` spares beyond the entries in use: `keep:`, an
  entry never removed, and `recent:`, how many of the others survive
  regardless of age (default 3), the most recently touched first.
  """
  @type prune_option :: {:keep, String.t()} | {:recent, non_neg_integer()}

  @doc """
  The entries of a checkout's store (`<checkout>/.argus-facts`) that
  `prune_facts/2` removes: `Argus.Cache.stale/2`'s — within each
  producer's shards and each program's solves, every entry untouched
  for an hour other than `keep:` and the `recent:` most recently
  touched — and, among the whole-facts entries an older argus kept
  (`<digest>/facts`), every one untouched for an hour beyond `keep:`
  and the `recent:` most recent; and a staging directory untouched for
  a day.

  An hour is how long an entry is presumed in use: a hit touches its
  entry, so one a VM beside this one is reading is never older than the
  run reading it. The `recent:` entries are the baselines: an agent that
  tallies before a change to extraction and again after needs the first
  entries still there at the end, however long the change took. A
  staging directory is one a VM is filling or one whose VM died
  mid-copy; after a day it is the latter.
  """
  @spec stale_facts(Path.t(), [prune_option()]) :: [Path.t()]
  def stale_facts(cache, opts \\ []) do
    Enum.sort(
      stale(cache, opts, &facts_entry_kind/2) ++
        Argus.Cache.stale(cache, Keyword.update(opts, :keep, [], &List.wrap/1))
    )
  end

  @doc """
  The kept solves of one facts cache entry (`<entry>/solves`, see
  `analyze/2`) that `prune_solves/2` removes, by `stale_facts/2`'s
  policy applied to each program on its own: every solve untouched for
  an hour beyond the `recent:` most recently touched of its program
  (default 3), other than `keep:`, and a staging directory untouched
  for a day. A rule edit leaves its program's earlier solves behind;
  the policy keeps the before-edit ones for a comparison, as it keeps
  the facts.
  """
  @spec stale_solves(Path.t(), [prune_option()]) :: [Path.t()]
  def stale_solves(solves, opts \\ []), do: stale(solves, opts, &solve_entry_kind/2)

  @doc """
  Removes `stale_solves/2` from one entry's kept solves; the paths it
  removed.
  """
  @spec prune_solves(Path.t(), [prune_option()]) :: [Path.t()]
  def prune_solves(solves, opts \\ []) do
    stale = stale_solves(solves, opts)
    Enum.each(stale, &File.rm_rf!/1)
    stale
  end

  # `Argus.Cache`'s retention policy: each group keeps its own
  # `recent:` survivors.
  defp stale(dir, opts, kind_of) do
    opts = Keyword.update(opts, :keep, [], &List.wrap/1)
    Argus.Cache.stale_entries(dir, opts, kind_of)
  end

  @doc """
  Removes `stale_facts/2` from a checkout's facts cache; the paths it
  removed.
  """
  @spec prune_facts(Path.t(), [prune_option()]) :: [Path.t()]
  def prune_facts(cache, opts \\ []) do
    stale = stale_facts(cache, opts)
    Enum.each(stale, &File.rm_rf!/1)
    stale
  end

  @doc "The facts cache of every checkout under `root/0` that has one."
  @spec facts_caches() :: [Path.t()]
  def facts_caches do
    for name <- ls(root()),
        cache = Path.join([root(), name, @facts_cache]),
        File.dir?(cache),
        do: cache
  end

  @doc "The kept solves of every installed entry of a facts cache."
  @spec solve_caches(Path.t()) :: [Path.t()]
  def solve_caches(cache) do
    for name <- ls(cache),
        facts_entry_kind(name, :directory) == {:installed, :facts},
        solves = Path.join([cache, name, @solves]),
        File.dir?(solves),
        do: solves
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  # A directory, never a file of that name.
  defp facts_entry_kind(_name, type) when type != :directory, do: nil

  defp facts_entry_kind(name, :directory) do
    cond do
      Regex.match?(~r/^[0-9a-f]{64}$/, name) -> {:installed, :facts}
      Regex.match?(~r/^[0-9a-f]{64}\.\d+\.\d+$/, name) -> :staging
      true -> nil
    end
  end

  # `<program>-<key>`, as `Argus.Souffle.Cache` names a kept solve.
  defp solve_entry_kind(_name, type) when type != :directory, do: nil

  defp solve_entry_kind(name, :directory) do
    case Regex.run(~r/^([a-z0-9_]+)-[0-9a-f]{64}(\.\d+\.\d+)?$/, name) do
      [_, program] -> {:installed, program}
      [_, _program, _staging] -> :staging
      nil -> nil
    end
  end

  # ── Steps ─────────────────────────────────────────────────────────────

  defp clone(pair, %{dir: dir, sha: sha} = co) do
    cloned =
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

    with :ok <- cloned, do: submodules(pair, co)
  end

  # A tree that vendors a dependency as a git submodule (aprs.me's
  # `vendor/aprs`, a path dependency) builds only with it checked out, at
  # the commit the tree records. Idempotent: a checkout that has it
  # updates nothing.
  defp submodules(%{submodules: true} = pair, %{dir: dir}),
    do:
      run(
        ["git", "submodule", "update", "--init", "--recursive", "-q"],
        dir,
        [],
        "submodules of #{pair.repo}"
      )

  defp submodules(_pair, _co), do: :ok

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

  @doc """
  The environment a pair's tree is compiled in: a clean one for the child
  mix (the parent runs in MIX_ENV=test with its own build paths, none of
  which the checkout must inherit), with the pair's `elixir:` and `otp:`
  asdf installs leading its `PATH`.
  """
  @spec compile_env(pair()) :: [{String.t(), String.t() | nil}]
  def compile_env(pair) do
    base = [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}, {"MIX_EXS", nil}]

    bins =
      for {key, dir} <- [elixir: "elixir", otp: "erlang"],
          version = Map.get(pair, key),
          do: Path.expand("~/.asdf/installs/#{dir}/#{version}/bin")

    # The Elixir's own MIX_HOME: an archive built for one OTP does not
    # load on another, and the parent's MIX_HOME is its own Elixir's.
    env =
      case Map.get(pair, :elixir) do
        nil ->
          base

        version ->
          home = Path.expand("~/.asdf/installs/elixir/#{version}/.mix")
          [{"ASDF_ELIXIR_VERSION", version}, {"MIX_HOME", home}, {"MIX_ARCHIVES", nil} | base]
      end

    env =
      case Map.get(pair, :otp) do
        nil -> env
        version -> [{"ASDF_ERLANG_VERSION", version} | env]
      end

    env =
      Enum.reduce(Map.get(pair, :env, %{}), env, fn {key, value}, acc ->
        List.keystore(acc, key, 0, {key, value})
      end)

    case bins do
      [] -> env
      bins -> [{"PATH", Enum.join(bins ++ [System.get_env("PATH", "")], ":")} | env]
    end
  end

  # An umbrella app builds into the umbrella's _build; the glob starts at
  # the project and climbs to the clone. Without a subdir the two are the
  # same directory, and a checkout may hold more than one build — each
  # beam counts once, from one build, or every call-site count doubles.
  defp beams(%{project: project, dir: dir, name: name} = co) do
    app = Map.get(co, :app) || app_name(project)

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

  # The command is looked up on the compile's PATH, which may lead with
  # the pair's own toolchain, not the parent's.
  defp run([cmd | args], cwd, env, step) do
    exe =
      case List.keyfind(env, "PATH", 0) do
        {"PATH", path} -> :os.find_executable(to_charlist(cmd), to_charlist(path)) || cmd
        nil -> cmd
      end

    case System.cmd(to_string(exe), args, cd: cwd, env: env, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "#{step} failed (exit #{status}):\n#{tail(out)}"}
    end
  end

  defp tail(out) do
    out |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")
  end
end
