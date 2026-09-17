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
  costs only the analysis. Nothing is added to the project's dependency
  set: argus runs over its `ebin` from this VM.

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
          optional(:module) => String.t(),
          required(:finding) => {atom(), String.t()}
        }

  @type checkout :: %{name: String.t(), dir: String.t(), sha: String.t()}

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
        %{name: name, dir: Path.join(root(), name), sha: sha}
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

  @doc "Runs every analysis over a checkout's beams; the findings as `Argus.run_analyses/2` returns them."
  @spec analyze([Path.t()]) :: {:ok, map()} | {:error, term()}
  def analyze(beams), do: Argus.run_analyses(beams, analyses: :all)

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

  # ── Steps ─────────────────────────────────────────────────────────────

  defp clone(pair, %{dir: dir, sha: sha}) do
    if File.dir?(dir) do
      :ok
    else
      File.mkdir_p!(root())
      url = "https://github.com/#{pair.repo}.git"

      with :ok <- run(["git", "clone", "-q", url, dir], root(), [], "clone #{pair.repo}"),
           :ok <- run(["git", "checkout", "-q", sha], dir, [], "checkout #{sha}") do
        relax_elixir_requirement(dir)
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

      with :ok <- build(dir, env, co.name) do
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

  defp beams(%{dir: dir, name: name}) do
    app = app_name(dir)

    case Path.wildcard(Path.join([dir, "_build", "*", "lib", app, "ebin", "*.beam"])) do
      [] -> {:error, "no beams for #{name} (app #{app})"}
      beams -> {:ok, beams}
    end
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
