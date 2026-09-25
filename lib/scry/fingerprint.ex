defmodule Scry.Fingerprint do
  @moduledoc """
  What the memoized graph is a function of beyond the beams, stamped by
  the driver into inputs.

  - `:env_fingerprint` (`env/1`) — what every query runs on: the Elixir
    and OTP versions, scry's own code (`code_digest/2`; a path
    dependency moves its code without moving its version), argus's fact
    schema version, and the applications on the code path
    (`Argus.Specs.environment_digest/1`), whose specs extraction reads
    for every remote callee — by version, and by beams for a dependency
    outside OTP and Elixir, less argus's own and the applications the
    scan watches (a read of one of those is tracked where it happens,
    by `Scry.Analysis`). Moving it re-extracts every module and re-runs
    every solve.
  - `:extraction_code` (`extraction_code/0`) — the code argus's fact
    producers run: the base (`Argus.Pipeline`'s emitter and the
    derivations every extraction makes) and each extractor scry runs,
    as `Argus.Cache.Code` walks it, joined into one digest with the
    schema modules. Argus ships extractor changes without moving its
    version or schema (and a path dependency never moves its version at
    all), so the version alone let a warm manifest serve rows the
    current code would not compute. Moving it re-extracts every module,
    and nothing above a module whose rows came out equal runs. An argus
    edit it does not reach — the findings' prose, the analyses modules,
    the Souffle wrapper, argus's caches, its corpus harness — extracts
    nothing.
  - `:argus_code` (`argus_code/0`) — every argus beam, debug info
    included: what the findings are built by (the analyses' prose,
    their identity rules), and where a program that calls argus has its
    specs read from. Rebuilding the findings is cheap, so any argus edit
    does.
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
          scry_code: String.t(),
          argus_schema: pos_integer(),
          specs_environment: String.t()
        }

  @typedoc "A `:rules_digest` key: an analysis, or a shared stage (`:stage0`, `:points_to`)."
  @type rules_key :: atom()

  @doc """
  The environment fingerprint: runtime versions, a digest of scry's
  code, argus's schema version, and a digest of the applications on the
  code path — except argus's own (`argus_code/0` keys a read of its
  specs) and `watched`, the applications whose beams the scan reads
  itself (the project, and its dependencies with `include_deps`). Their
  beams move with every edit, and the graph already tracks each one: an
  analyzed module as a `:beam_meta` input, an ignored one as an
  `:ignored_beam` input its callers depend on. Each excluded application
  is still named, by version.
  """
  @spec env([atom()]) :: env()
  def env(watched \\ []) do
    %{
      elixir: System.version(),
      otp: System.otp_release(),
      scry: app_vsn(:scry),
      scry_code: app_code_digest(:scry),
      argus_schema: Argus.Schema.version(),
      # Extraction reads remote callees' specs off the code path; this
      # names every application there by version, and a dependency
      # outside OTP and Elixir also by its beams (a path dependency moves
      # its code without moving its version).
      specs_environment: Argus.Specs.environment_digest(exclude: Enum.uniq([:panoptes | watched]))
    }
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
  code path): the union of `Argus.Cache.Code.closure/1` over the base
  and every extractor scry runs (`Scry.Analysis.all_extractors/0`), and
  `Argus.Schema` with every `Argus.Schema.*` module, which name the
  relations and their columns every producer writes. The schema modules
  are listed whether or not a closure reaches them: argus is moving them
  out of the closures, to key the schema reads a producer records
  instead, and until scry keys on those reads the schema must stay in
  this digest.
  """
  @spec extraction_closure() ::
          {:ok, [{module(), Path.t() | :absent}]} | {:error, {:no_beam, module()}}
  def extraction_closure do
    Enum.reduce_while(producers(), {:ok, schema_modules()}, fn producer, {:ok, acc} ->
      case Argus.Cache.Code.closure(producer) do
        {:ok, modules} -> {:cont, {:ok, Map.merge(acc, Map.new(modules))}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, modules} -> check_beams(Enum.sort(modules))
      {:error, _} = error -> error
    end
  end

  defp producers, do: [:base | Scry.Analysis.all_extractors()]

  defp schema_modules do
    _ = Application.load(:panoptes)

    for module <- Application.spec(:panoptes, :modules) || [],
        schema_module?(module),
        into: %{},
        do: {module, where(module)}
  end

  defp schema_module?(Argus.Schema), do: true

  defp schema_module?(module),
    do: String.starts_with?(Atom.to_string(module), "Elixir.Argus.Schema.")

  defp where(module) do
    case :code.which(module) do
      :non_existing -> :absent
      path when is_list(path) and path != [] -> List.to_string(path)
      _in_memory_or_cover_compiled -> :no_beam
    end
  end

  defp check_beams(modules) do
    case Enum.find(modules, &match?({_module, :no_beam}, &1)) do
      nil -> {:ok, modules}
      {module, :no_beam} -> {:error, {:no_beam, module}}
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
