defmodule Scry.Fingerprint do
  @moduledoc """
  What the memoized graph is a function of beyond the beams, stamped by
  the driver into inputs.

  - `:env_fingerprint` (`env/0`) — what every query runs on: the Elixir
    and OTP versions, and scry's own code, digested from its ebin
    (`code_digest/2`; a path dependency moves its code without moving
    its version). Moving it re-extracts every module and re-solves every
    analysis.
  - `:producer_digest` (`producers/2`) — per argus producer (`:base`,
    the facts every extraction makes, or one extractor), the code it
    runs: `Argus.Cache.Code`'s digest of the modules it reaches, argus's
    and its dependencies', by content. The specs extractor also reads
    specs off the code path, so its digest adds the applications there
    (`Argus.Specs.environment_digest/1`), less argus's own and the
    applications the scan watches: an edit to one of those is tracked
    per read (`Scry.Analysis`). An argus edit moves the digests of the
    producers it reached and no other, so only their rows are extracted
    again, and a solve re-runs only when the rows came out different.
    The runner takes the digests again only when what they are a
    function of moved (`producer_stamp/2`).
  - `:argus_code` (`argus_code/0`) — every argus beam, specs included: what
    the findings are built by (the analyses' prose, their identity
    rules), which runs over solved rows and so moves no fact. Rebuilding
    every analysis's findings is cheap, so any argus edit does.
  - `:rules_digest` (`rules/1`) — per analysis (and `:stage0`,
    `:points_to`), the Datalog it runs: its rules file and everything
    that file `.include`s, transitively, plus the solver's version. A
    rule edit moves only the digests of the analyses whose programs
    contain the edited file, so exactly those re-solve, and nothing is
    re-extracted. How argus runs the solver and reads its output back
    is keyed the way argus's own solve store keys it: by the program
    and the solver, not by argus's code.

  Anything else that changes an extraction or a solve without changing
  a beam must move a value here, or a warm manifest serves results the
  current toolchain would not compute.
  """

  @typedoc "The `:env_fingerprint` input's value."
  @type env :: %{
          elixir: String.t(),
          otp: String.t(),
          scry: String.t(),
          scry_code: String.t()
        }

  @typedoc """
  A `:producer_digest` input's value: the producer's code, and — for a
  producer that reads specs off the code path — the environment it
  reads them from.
  """
  @type producer_digest :: %{code: String.t(), environment: String.t() | nil}

  @typedoc "A `:rules_digest` key: an analysis, or a shared stage (`:stage0`, `:points_to`)."
  @type rules_key :: atom()

  @doc """
  The environment fingerprint: runtime versions and a digest of scry's
  code.
  """
  @spec env() :: env()
  def env do
    %{
      elixir: System.version(),
      otp: System.otp_release(),
      scry: app_vsn(:scry),
      scry_code: app_code_digest(:scry)
    }
  end

  @doc false
  @deprecated "The watched applications key the specs extractor now: use env/0 and producers/2"
  @spec env([atom()]) :: env()
  def env(_watched), do: env()

  @doc """
  The digest of each of `producers` (`Scry.Analysis.producers/0`).

  The code is `Argus.Cache.Code.digest/1`'s. A producer whose code it
  cannot key (a module with no beam on disk: compiled in memory, or
  cover-compiled) falls back to every argus beam, as a whole.

  A producer that reads specs off the code path
  (`Argus.Cache.Code.reads_installed?/1`) also carries the environment:
  every application there by version, and a dependency outside OTP and
  Elixir by its beams — except argus's own and `watched`, the
  applications whose beams the scan reads itself (the project, and its
  dependencies with `include_deps`). Their beams move with every edit,
  and the graph tracks each read of one: an analyzed module through
  its `:file_of`, an ignored one through its `:ignored_beam`, one of
  argus's through `:argus_code`.
  """
  @spec producers([Argus.Pipeline.producer()], [atom()]) ::
          %{optional(Argus.Pipeline.producer()) => producer_digest()}
  def producers(producers, watched \\ []) do
    # Every extractor's closure holds the base's: digesting the base
    # first memoizes those modules' digests for the rest, which then run
    # side by side.
    _ = Argus.Cache.Code.digest(:base)

    codes =
      producers
      |> Task.async_stream(&{&1, code_digest_of(&1)}, ordered: true, timeout: :infinity)
      |> Map.new(fn {:ok, entry} -> entry end)

    Map.new(producers, fn producer ->
      environment =
        if Argus.Cache.Code.reads_installed?(producer), do: specs_environment(watched)

      {producer, %{code: Map.fetch!(codes, producer), environment: environment}}
    end)
  end

  @doc """
  What every digest `producers/2` takes is a function of, and cheap to
  take where the digests are not (each walks its code's import tables in
  a fresh VM): the runtime, argus's code (`argus_code/0`'s value), and
  the specs environment less argus and `watched` — every other
  application on the code path, by its beams outside OTP and Elixir. A
  producer's code lies in argus and the applications it runs, and stops
  at OTP and Elixir, which the versions name; one it calls that is not
  there arrives with an application, which the environment names. While
  the stamp holds, so does every digest.

  `nil` when `watched` holds argus or an application it runs (a scan
  with `include_deps`): the environment leaves those beams out, and they
  are code a producer runs.
  """
  @spec producer_stamp(String.t(), [atom()]) :: term() | nil
  def producer_stamp(argus_code, watched) do
    argus = argus_applications()

    if Enum.any?(watched, &Map.has_key?(argus, &1)),
      do: nil,
      else: {System.version(), System.otp_release(), argus_code, specs_environment(watched)}
  end

  defp specs_environment(watched),
    do: Argus.Specs.environment_digest(exclude: Enum.uniq([:panoptes | watched]))

  # Argus and every application it runs, transitively, as the keys of a
  # map (dialyzer cannot follow an opaque set through the recursion).
  defp argus_applications, do: applications([:panoptes], %{})

  defp applications([], seen), do: seen

  defp applications([app | rest], seen) when is_map_key(seen, app), do: applications(rest, seen)

  defp applications([app | rest], seen) do
    _ = Application.load(app)
    runs = Application.spec(app, :applications) || []
    included = Application.spec(app, :included_applications) || []
    applications(runs ++ included ++ rest, Map.put(seen, app, true))
  end

  defp code_digest_of(producer) do
    case Argus.Cache.Code.digest(producer) do
      {:ok, digest} -> digest
      {:error, _no_beam} -> "argus:" <> argus_code()
    end
  end

  @doc """
  A digest of every argus beam, debug info (where specs are read from)
  included: moves with any argus edit.
  """
  @spec argus_code() :: String.t()
  def argus_code, do: app_code_digest(:panoptes, debug_info: true)

  @doc """
  The rules digest of each of `analyses`, and of `:stage0` and
  `:points_to` (the shared call graph and process points-to programs
  the solves read). Each covers the analysis's
  rules file, every file it includes, transitively, and the solver's
  version (`souffle_version/0`).
  """
  @spec rules([atom()]) :: %{optional(rules_key()) => String.t()}
  def rules(analyses) do
    souffle = souffle_version()

    programs =
      [
        {:stage0, Argus.Analysis.stage0_rules_path()},
        {:points_to, Argus.Analysis.points_to_rules_path()}
      ] ++
        for analysis <- analyses, {:ok, path} <- [rules_path(analysis)], do: {analysis, path}

    Map.new(programs, fn {key, path} -> {key, digest({souffle, program_digest(path)})} end)
  end

  @doc """
  A digest of the Datalog program rooted at `path`: the file and every
  file it `.include`s, transitively, by path relative to the root's
  directory and content. A missing include is part of the digest as
  missing, so creating it moves the value.
  """
  @spec program_digest(Path.t()) :: String.t()
  def program_digest(path) do
    path = Path.expand(path)
    base = Path.dirname(path)

    path
    |> include_closure(MapSet.new())
    |> Enum.sort()
    |> Enum.map(fn file ->
      content =
        case File.read(file) do
          {:ok, content} -> {:ok, content}
          {:error, _} -> :missing
        end

      {Path.relative_to(file, base), content}
    end)
    |> digest()
  end

  # Souffle resolves an include against the including file's directory.
  # A commented-out include is still followed: an extra file in the
  # digest costs a spurious re-solve at worst, a missed one a stale
  # result.
  defp include_closure(file, seen) do
    if MapSet.member?(seen, file) do
      seen
    else
      seen = MapSet.put(seen, file)

      case File.read(file) do
        {:ok, content} ->
          ~r/^\s*(?:\/\/\s*)?\.include\s+"([^"]+)"/m
          |> Regex.scan(content, capture: :all_but_first)
          |> Enum.reduce(seen, fn [include], seen ->
            include_closure(Path.expand(include, Path.dirname(file)), seen)
          end)

        {:error, _} ->
          seen
      end
    end
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
