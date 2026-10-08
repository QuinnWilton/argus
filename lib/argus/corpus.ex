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

  On the query graph (the default), each checkout keeps its graph in a
  manifest beside it, `.argus/manifest-<worktree>`, one per argus
  worktree (`worktree/0`: the code that computed a manifest's entries is
  that worktree's), its facts and solves in the shared blob store
  (`Argus.Graph.store/0`). A worktree with no manifest for a checkout
  starts from the newest another worktree kept there: roux drops the
  entries of every query whose code differs, and the rest hold. A warm
  run executes nothing but its reads; after an edit to one extractor,
  every module's facts run that extractor alone.

  The blob store is collected by `argus gc` (and once a day by every
  driver run); a checkout's manifest goes with the checkout.

  `analyze_all/2` runs checkouts `jobs/0` at a time; the test gate and
  `mix argus.corpus tally` both go through it.

  The project's `elixir:` requirement is relaxed so an old tree builds on
  the current toolchain; a pair may name an `elixir:` version instead,
  exported as `ASDF_ELIXIR_VERSION` for the compile, and an `otp:`
  version, whose asdf install's `bin` leads the compile's `PATH` (a
  locked Erlang dependency that no longer builds on OTP 28, like an old
  rabbit_common's `'street-address'` macro). The two go together: an
  Elixir built for OTP 28 does not load on 27.

  ## What a machine cannot check

  A pair this machine cannot build is skipped, with the reason, by the
  gate and by `mix argus.corpus fetch` (`ensure/2` answers `{:skip,
  reason}`), and checked wherever it can be: its trees need an Erlang or
  Elixir without an asdf install here and one is not compiled yet
  (`unbuildable/1`), or its repository cannot be fetched (gone, private,
  or no network) and a tree is not checked out yet (`unfetchable/1`: a
  repository whose trees survive only in a cache still runs there).

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

  alias Argus.Graph.Environment

  @typedoc """
  A closed-issue pair: `repo` is `owner/name` on GitHub, or a git URL.
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
          optional(:function) => {atom(), non_neg_integer()},
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

  @doc """
  The issues `ARGUS_CORPUS_ONLY` narrows a run to (substrings of an
  issue's name, comma-separated), or nil when it names none.
  """
  @spec only() :: [String.t()] | nil
  def only do
    case System.get_env("ARGUS_CORPUS_ONLY") do
      nil -> nil
      s -> s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  @doc "The pairs `only/0` keeps: every pair when it names none."
  @spec selected() :: [pair()]
  def selected do
    case only() do
      nil ->
        pairs()

      only ->
        Enum.filter(pairs(), fn pair -> Enum.any?(only, &String.contains?(pair.issue, &1)) end)
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

  Returns the `.beam` files of the project's own application;
  `{:skip, reason}` when this machine cannot build the tree (see "What a
  machine cannot check"); or an error naming the step that failed and
  its log.
  """
  @spec ensure(pair(), :pre | :fix) ::
          {:ok, [Path.t()]} | {:skip, String.t()} | {:error, String.t()}
  def ensure(pair, side) do
    with %{} = co <- checkout(pair, side) || {:error, "no #{side} side for #{pair.issue}"},
         :ok <- buildable(pair, co),
         :ok <- clone(pair, co),
         :ok <- compile(pair, co) do
      beams(co)
    end
  end

  @doc """
  Why this machine cannot build `pair`, or nil: a side it has not
  compiled yet, and an `otp:` or `elixir:` version the pair names that
  has no asdf install here. Compiled on the running toolchain instead, a
  tree fails on what the pair names its toolchain for, or builds as
  another tree than the one the pair was verified on.
  """
  @spec unbuildable(pair()) :: String.t() | nil
  def unbuildable(pair) do
    uncompiled? =
      Enum.any?([:pre, :fix], fn side ->
        case checkout(pair, side) do
          nil -> false
          co -> not File.exists?(marker(co))
        end
      end)

    case missing_toolchain(pair) do
      [] -> nil
      _missing when not uncompiled? -> nil
      missing -> "#{pair.issue} needs #{Enum.join(missing, " and ")}"
    end
  end

  defp buildable(pair, co) do
    case missing_toolchain(pair) do
      [] ->
        :ok

      missing ->
        if File.exists?(marker(co)),
          do: :ok,
          else: {:skip, "#{co.name} needs #{Enum.join(missing, " and ")}"}
    end
  end

  @doc """
  Why `pair`'s repository cannot be fetched here, or nil: a side is not
  checked out yet, and `git ls-remote` of the repository fails (it is
  gone or private, or there is no network). Asks the repository's host
  on every call, and nothing when every side is checked out.
  """
  @spec unfetchable(pair()) :: String.t() | nil
  def unfetchable(pair) do
    missing? =
      Enum.any?([:pre, :fix], fn side ->
        case checkout(pair, side) do
          nil -> false
          co -> not File.dir?(co.dir)
        end
      end)

    with true <- missing?,
         {:error, why} <- reachable(url(pair)) do
      "#{pair.issue}: #{unfetched(pair, why)}"
    else
      _ -> nil
    end
  end

  # Whether `url` answers: a stalled transfer gives up, and a host asking
  # for credentials (GitHub, for a repository that is gone or private)
  # is refused rather than prompted for, as a terminal would be.
  defp reachable(url) do
    task =
      Task.async(fn ->
        run(
          [
            "git",
            "-c",
            "http.lowSpeedLimit=1",
            "-c",
            "http.lowSpeedTime=30",
            "ls-remote",
            url,
            "HEAD"
          ],
          File.cwd!(),
          git_env(),
          "ls-remote #{url}"
        )
      end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "ls-remote #{url} timed out after 60 s"}
    end
  end

  defp unfetched(pair, why),
    do: "#{pair.repo} cannot be fetched, and is not checked out here (#{git_reason(why)})"

  # The line of a failed git step's output that says why: its first
  # `fatal:` line, else its first line past the step's own.
  defp git_reason(why) do
    lines =
      why
      |> String.split("\n")
      |> Enum.drop(1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.find(lines, List.first(lines, why), &String.starts_with?(&1, "fatal:"))
  end

  # Git never waits on a terminal for credentials.
  defp git_env, do: [{"GIT_TERMINAL_PROMPT", "0"}]

  defp url(%{repo: repo}) do
    if String.contains?(repo, "://"), do: repo, else: "https://github.com/#{repo}.git"
  end

  # Each asdf install the pair names that this machine does not have,
  # with what installs it.
  defp missing_toolchain(pair) do
    for {key, plugin, name} <- [{:otp, "erlang", "Erlang/OTP"}, {:elixir, "elixir", "Elixir"}],
        version = Map.get(pair, key),
        not File.dir?(asdf_install(plugin, version)),
        do: "#{name} #{version} (`asdf install #{plugin} #{version}`)"
  end

  defp asdf_install(plugin, version), do: Path.expand("~/.asdf/installs/#{plugin}/#{version}")

  @doc """
  Runs every analysis over one side of a pair; the findings as
  `Argus.run_analyses/2` returns them.

  Clones and compiles the checkout if needed (`ensure/2`), then runs on
  the query graph with the checkout's manifest (`manifest/1`) over the
  shared blob store: only what an edit reached since the last run runs
  again. Under `ARGUS_NO_CACHE` nothing is kept, and everything runs.
  `opts` may carry the code directories' `stamps:`, read once for many
  checkouts (`analyze_all/2`).
  """
  @spec analyze(pair(), :pre | :fix, keyword()) ::
          {:ok, Argus.Findings.t()} | {:skip, String.t()} | {:error, term()}
  def analyze(pair, side, opts \\ []) do
    with %{} = co <- checkout(pair, side) || {:error, "no #{side} side for #{pair.issue}"},
         {:ok, beams} <- ensure(pair, side) do
      Argus.run_analyses(beams, [analyses: :all] ++ graph_opts(co, opts))
    end
  end

  # The graph's options for a checkout: its manifest, and the code
  # directories' stamps when the caller read them for many checkouts.
  # Under `ARGUS_NO_CACHE` nothing is kept.
  defp graph_opts(co, opts) do
    if Argus.Dirs.keep?(),
      do: [manifest: seed_manifest(manifest(co))] ++ Keyword.take(opts, [:stamps]),
      else: []
  end

  @doc """
  The manifest this worktree keeps a checkout's graph in:
  `<checkout>/.argus/manifest-<worktree/0>`.
  """
  @spec manifest(checkout()) :: Path.t()
  def manifest(%{dir: dir}), do: Path.join([dir, ".argus", "manifest-" <> worktree()])

  @doc """
  This argus worktree, as a manifest's name says it: the first 16 hex
  digits of the SHA-256 of the directory it was built from.
  """
  @spec worktree() :: String.t()
  def worktree do
    root = Path.expand("../..", __DIR__)
    :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  @doc """
  `manifest`, seeded when absent from the newest manifest another
  worktree kept beside it (a copy, which this worktree then keeps as its
  own); returns `manifest`.
  """
  @spec seed_manifest(Path.t()) :: Path.t()
  def seed_manifest(manifest) do
    dir = Path.dirname(manifest)

    unless File.exists?(manifest) do
      siblings =
        for name <- ls(dir),
            String.starts_with?(name, "manifest-"),
            path = Path.join(dir, name),
            path != manifest,
            {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(path, time: :posix)],
            do: {mtime, path}

      case Enum.max_by(siblings, &elem(&1, 0), fn -> nil end) do
        nil ->
          :ok

        {_mtime, newest} ->
          # Under a name of its own, then renamed: a worktree beside
          # this one seeding the same checkout never reads half a copy.
          staging = "#{manifest}.#{:os.getpid()}.#{System.unique_integer([:positive])}"

          with :ok <- File.cp(newest, staging),
               :ok <- File.rename(staging, manifest) do
            :ok
          else
            _ -> File.rm(staging)
          end
      end
    end

    manifest
  end

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
          ({:ok, Argus.Findings.t()} | {:skip, String.t()} | {:error, term()} -> result)
        ) :: [{checkout(), result}]
        when result: term()
  def analyze_all(checkouts, reduce \\ & &1) do
    # Every checkout reads its callees' specs from this VM's code path:
    # its directories are stamped once for them all.
    opts = [stamps: Environment.stamps(Environment.code_index())]

    # Unordered, then sorted back: a large tree finishing late holds up
    # no other checkout's slot.
    checkouts
    |> Enum.with_index()
    |> Task.async_stream(
      fn {{co, pair, side}, index} -> {index, co, reduce.(analyze(pair, side, opts))} end,
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
  and — when the pair names a `module:` — anchored in that module. An optional
  `function: {name, arity}` selects the affected function when another function
  in the same module legitimately retains the finding. The
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
        (module == nil or inspect(f.module) == module) and
        in_function?(f, Map.get(pair, :function))
    end)
  end

  defp in_function?(_finding, nil), do: true
  defp in_function?(%{mfa: {_, name, arity}}, {name, arity}), do: true
  defp in_function?(_finding, _function), do: false

  # ── Helpers ──────────────────────────────────────────────────────────

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  # ── Steps ─────────────────────────────────────────────────────────────

  defp clone(pair, %{dir: dir, sha: sha} = co) do
    cloned =
      if File.dir?(dir) do
        :ok
      else
        File.mkdir_p!(root())

        # A clone that fails leaves no directory: the tree is not here.
        fetched =
          case run(["git", "clone", "-q", url(pair), dir], root(), git_env(), "clone") do
            :ok -> :ok
            {:error, why} -> {:skip, "#{co.name}: #{unfetched(pair, why)}"}
          end

        with :ok <- fetched,
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

  # What records that a checkout compiled.
  defp marker(%{dir: dir, sha: sha}),
    do: Path.join(dir, ".argus-compiled-#{String.slice(sha, 0, 7)}")

  defp compile(pair, co) do
    marker = marker(co)

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
      for {key, plugin} <- [elixir: "elixir", otp: "erlang"],
          version = Map.get(pair, key),
          do: Path.join(asdf_install(plugin, version), "bin")

    # The Elixir's own MIX_HOME: an archive built for one OTP does not
    # load on another, and the parent's MIX_HOME is its own Elixir's.
    env =
      case Map.get(pair, :elixir) do
        nil ->
          base

        version ->
          home = Path.join(asdf_install("elixir", version), ".mix")
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
