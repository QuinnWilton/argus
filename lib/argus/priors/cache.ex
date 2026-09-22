defmodule Argus.Priors.Cache do
  @moduledoc """
  Every answer, kept: a request is never paid for twice.

  Content-addressed. The key is a digest of the generation — model,
  question module, prompt version — and the request itself, so a change
  to any of them is a different key and the old answers simply stop
  being hit; `clear/1` removes them. Entries are JSON files under
  `ARGUS_PRIORS_DIR` (default `~/.cache/argus/priors`), one directory per
  generation, mirroring `Argus.Corpus`'s cache.

  A cassette is the entries for one project in a single JSONL file:
  `export/2` writes one for a set of keys, `import/1` reads it back, and
  a run in `:cached_only` mode with an imported cassette is deterministic
  and needs no network — which is what a test suite or a CI run wants.
  """

  @type generation :: %{model: String.t(), question: String.t(), prompt_version: pos_integer()}
  @type entry :: %{
          key: String.t(),
          generation: generation(),
          request: map(),
          response: map(),
          at: String.t()
        }

  @doc "Where entries live."
  @spec root() :: Path.t()
  def root do
    case System.get_env("ARGUS_PRIORS_DIR") do
      nil -> Path.expand("~/.cache/argus/priors")
      dir -> Path.expand(dir)
    end
  end

  @doc """
  The key of a request under a generation: identical for identical
  requests whatever the map ordering, different for any other.
  """
  @spec key(generation(), map()) :: String.t()
  def key(generation, request) do
    %{generation: generation, request: request}
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%{} = map),
    do: {:map, map |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end) |> Enum.sort()}

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)

  defp canonical(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp canonical(other), do: other

  @doc "The cached entry for a key, if any."
  @spec get(Path.t(), generation(), String.t()) :: {:ok, entry()} | :miss
  def get(dir \\ root(), generation, key) do
    path = path(dir, generation, key)

    with true <- File.exists?(path),
         {:ok, json} <- File.read(path),
         {:ok, decoded} <- JSON.decode(json) do
      {:ok, entry_from_json(decoded)}
    else
      _ -> :miss
    end
  end

  @doc "Records an answer."
  @spec put(Path.t(), generation(), String.t(), map(), map()) :: :ok | {:error, term()}
  def put(dir \\ root(), generation, key, request, response) do
    entry = %{
      key: key,
      generation: generation,
      request: request,
      response: response,
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    path = path(dir, generation, key)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, JSON.encode!(entry))
    end
  end

  @doc "Every entry under `dir`, by generation directory."
  @spec entries(Path.t()) :: %{String.t() => [entry()]}
  def entries(dir \\ root()) do
    [dir, "*", "*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.group_by(&(&1 |> Path.dirname() |> Path.basename()), &read_entry!/1)
  end

  @doc "Removes every entry, or those of one generation directory."
  @spec clear(Path.t(), keyword()) :: {:ok, non_neg_integer()}
  def clear(dir \\ root(), opts \\ []) do
    paths =
      case Keyword.get(opts, :generation) do
        nil -> Path.wildcard(Path.join([dir, "*", "*.json"]))
        gen -> Path.wildcard(Path.join([dir, gen, "*.json"]))
      end

    Enum.each(paths, &File.rm!/1)
    {:ok, length(paths)}
  end

  @doc "Writes the entries for `keys` (or all) as a JSONL cassette."
  @spec export(Path.t(), Path.t(), keyword()) :: {:ok, non_neg_integer()}
  def export(dir \\ root(), path, opts \\ []) do
    wanted = Keyword.get(opts, :keys)

    entries =
      dir
      |> entries()
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(is_nil(wanted) or &1.key in wanted))
      |> Enum.sort_by(& &1.key)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(entries, &[JSON.encode!(&1), "\n"]))
    {:ok, length(entries)}
  end

  @doc "Reads a cassette into the cache; an entry already present is left alone."
  @spec import(Path.t(), Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import(dir \\ root(), path) do
    with {:ok, content} <- File.read(path) do
      entries =
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> JSON.decode!() |> entry_from_json()))

      for e <- entries, not File.exists?(path(dir, e.generation, e.key)) do
        :ok = put(dir, e.generation, e.key, e.request, e.response)
      end

      {:ok, length(entries)}
    end
  end

  @doc "The generation directory name."
  @spec generation_dir(generation()) :: String.t()
  def generation_dir(%{model: model, question: question, prompt_version: v}) do
    short = question |> String.replace_prefix("Elixir.", "") |> String.split(".") |> List.last()
    sanitize("#{model}--#{short}--v#{v}")
  end

  defp sanitize(name), do: String.replace(name, ~r/[^A-Za-z0-9._-]/, "_")

  defp path(dir, generation, key),
    do: Path.join([dir, generation_dir(generation), key <> ".json"])

  defp read_entry!(path), do: path |> File.read!() |> JSON.decode!() |> entry_from_json()

  defp entry_from_json(
         %{"key" => key, "generation" => g, "request" => req, "response" => resp} = e
       ) do
    %{
      key: key,
      generation: %{
        model: g["model"],
        question: g["question"],
        prompt_version: g["prompt_version"]
      },
      request: req,
      response: resp,
      at: Map.get(e, "at")
    }
  end
end
