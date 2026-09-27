defmodule Argus.Config.Source do
  @moduledoc """
  Where a project's argus configuration is read from, before
  `Argus.Config.load/2` validates it.

    * `mix/1` — `argus:` in a Mix project's `project/0`;
    * `rebar3/1` — `{argus, [...]}` in a `rebar.config`, read with
      `:file.consult/1`: the file is consulted, never evaluated (a
      `rebar.config.script` is not read). The rebar3 plugin's own keys
      live beside it under `{argus_plugin, [...]}`, which argus leaves
      to the plugin;
    * `file/1` — an `argus.config` of Erlang terms, for a Gleam or
      erlang.mk project or a directory of beams: a list of `{Key, Value}`
      tuples, or one such tuple per term.

  Each returns the raw configuration with its origin. A file that
  cannot be read or parsed raises `Argus.ConfigError`; so does
  configuration under scry's name, which argus has replaced (`scry:` in
  a Mix project, or the `:scry` compiler): it would otherwise be
  silently ignored.
  """

  alias Argus.ConfigError

  @typedoc "A raw configuration and where it came from."
  @type t :: {keyword() | term(), Argus.Config.origin()}

  @doc """
  The current Mix project's `argus:` keyword (empty when it has none).
  `project` is its `project/0` keyword, the current project's by
  default.
  """
  @spec mix(keyword()) :: t()
  def mix(project \\ Mix.Project.config()) do
    origin = {:mix, mix_exs()}

    cond do
      Keyword.has_key?(project, :scry) ->
        raise ConfigError.renamed("scry:", "argus:", origin)

      :scry in List.wrap(Keyword.get(project, :compilers, [])) ->
        raise ConfigError.renamed("the :scry compiler", "the :argus compiler", origin)

      true ->
        {Keyword.get(project, :argus, []), origin}
    end
  end

  defp mix_exs do
    case Mix.Project.project_file() do
      nil -> "mix.exs"
      path -> path
    end
  end

  @doc """
  `{argus, Config}` in the `rebar.config` at `path` (`[]` when it names
  none).
  """
  @spec rebar3(Path.t()) :: t()
  def rebar3(path) do
    terms = consult!(path)
    origin = {:rebar3, path}

    case List.keyfind(terms, :argus, 0) do
      {:argus, raw} -> {raw, origin}
      nil -> {[], origin}
    end
  end

  @doc """
  The `argus.config` at `path`: one list of `{Key, Value}` tuples, or
  one tuple per term.
  """
  @spec file(Path.t()) :: t()
  def file(path) do
    origin = {:file, path}

    case consult!(path) do
      [raw] when is_list(raw) -> {raw, origin}
      terms -> {terms, origin}
    end
  end

  @doc """
  The configuration of a project rooted at `root`, from its own source:
  `rebar.config` for rebar3, `argus.config` for the rest, `[]` when the
  file is not there. `config` (`--config`) names a file to read instead:
  a `rebar.config` is read as rebar3's, anything else as an
  `argus.config`.
  """
  @spec for_project(Path.t(), :rebar3 | atom(), Path.t() | nil) :: t()
  def for_project(root, kind, config \\ nil)

  def for_project(_root, _kind, config) when is_binary(config) do
    if Path.basename(config) == "rebar.config", do: rebar3(config), else: file(config)
  end

  def for_project(root, :rebar3, nil) do
    path = Path.join(root, "rebar.config")
    if File.regular?(path), do: rebar3(path), else: {[], {:rebar3, path}}
  end

  def for_project(root, _kind, nil) do
    path = Path.join(root, "argus.config")
    if File.regular?(path), do: file(path), else: {[], {:file, path}}
  end

  defp consult!(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} ->
        terms

      {:error, {line, module, reason}} ->
        raise ConfigError.unreadable(
                path,
                "line #{line}: #{module.format_error(reason) |> IO.chardata_to_string()}"
              )

      {:error, reason} ->
        raise ConfigError.unreadable(path, :file.format_error(reason) |> IO.chardata_to_string())
    end
  end
end
