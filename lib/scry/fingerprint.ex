defmodule Scry.Fingerprint do
  @moduledoc """
  What the memoized graph is a function of beyond the beams, stamped by
  the driver into two inputs.

  - `:env_fingerprint` (`env/0`) — everything an extraction depends on:
    the runtime, the fact schema, and the argus and scry code itself,
    digested from their ebins. Argus ships extractor and findings
    changes without moving its version or schema (and a path
    dependency never moves its version at all), so the version alone
    let a warm manifest serve rows the current code would not compute.
    Moving it re-extracts every module.
  - `:rules_digest` (`rules/1`) — per analysis (and `:stage0`), the
    Datalog it runs: its rules file and everything that file
    `.include`s, transitively, plus the solver's version. A rule edit
    moves only the digests of the analyses whose programs contain the
    edited file, so exactly those re-solve, and nothing is
    re-extracted.

  Anything else that changes an extraction or a solve without changing
  a beam must move a value here, or a warm manifest serves results the
  current toolchain would not compute.
  """

  @typedoc "The `:env_fingerprint` input's value."
  @type env :: %{
          elixir: String.t(),
          otp: String.t(),
          argus: String.t(),
          argus_code: String.t(),
          scry: String.t(),
          scry_code: String.t(),
          argus_schema: pos_integer()
        }

  @typedoc "A `:rules_digest` key: an analysis, or the shared stage 0."
  @type rules_key :: atom()

  @doc """
  The environment fingerprint: runtime versions, the argus schema, and
  digests of the argus and scry code on the code path.
  """
  @spec env() :: env()
  def env do
    %{
      elixir: System.version(),
      otp: System.otp_release(),
      argus: app_vsn(:panoptes),
      argus_code: app_code_digest(:panoptes),
      scry: app_vsn(:scry),
      scry_code: app_code_digest(:scry),
      argus_schema: Argus.Schema.version()
    }
  end

  @doc """
  The rules digest of each of `analyses`, and of `:stage0` (the shared
  call-graph program every solve reads). Each covers the analysis's
  rules file, every file it includes, transitively, and the solver's
  version (`souffle_version/0`).
  """
  @spec rules([atom()]) :: %{optional(rules_key()) => String.t()}
  def rules(analyses) do
    souffle = souffle_version()

    programs =
      [{:stage0, Argus.Analysis.stage0_rules_path()}] ++
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
  A digest of every `.beam` in `ebin`, by name and content.
  """
  @spec code_digest(Path.t()) :: String.t()
  def code_digest(ebin) do
    ebin
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce(:erlang.md5_init(), fn beam, context ->
      context
      |> :erlang.md5_update(Path.basename(beam))
      |> :erlang.md5_update(File.read!(beam))
    end)
    |> :erlang.md5_final()
    |> Base.encode16(case: :lower)
  end

  defp app_code_digest(app) do
    case :code.lib_dir(app) do
      {:error, _} -> "unknown"
      dir -> code_digest(Path.join(to_string(dir), "ebin"))
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
