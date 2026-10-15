defmodule Argus.Test.Fixtures.DecodedOrigin do
  @moduledoc """
  Deserializations of a BEAM file's own terms and of the build's own
  files, each the analyzed code's or the build's bytes on every path:
  argus's docs extractor and compile task, and roux's beam digest, which
  hands each chunk to a private normalizer through a reduce.
  """

  def docs(beam) do
    with {:ok, {_module, [{~c"Docs", chunk}]}} <- :beam_lib.chunks(beam, [~c"Docs"]) do
      :erlang.binary_to_term(chunk)
    end
  end

  def digest(beam) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(beam)

    chunks
    |> Enum.map(fn {id, data} -> {List.to_string(id), data} end)
    |> Enum.reject(fn {id, _} -> id == "Line" end)
    |> Enum.reduce(0, fn {id, data}, acc -> :erlang.phash2({acc, normalize(id, data)}) end)
  end

  defp normalize("Attr", data), do: decode(data)
  defp normalize(_id, data), do: data

  defp decode(data), do: :erlang.binary_to_term(data)

  def literal_table(beam) do
    {:ok, {_module, [{~c"LitT", <<size::32, table::binary>>}]}} =
      :beam_lib.chunks(beam, [~c"LitT"])

    <<_count::32, entries::binary>> = if size == 0, do: table, else: :zlib.uncompress(table)
    for <<len::32, term::binary-size(len) <- entries>>, do: :erlang.binary_to_term(term)
  end

  def sidecar do
    with {:ok, binary} <- File.read(sidecar_file()), do: :erlang.binary_to_term(binary)
  end

  defp sidecar_file, do: Path.join(Mix.Project.manifest_path(), "argus.sidecar")
end

defmodule Argus.Test.Fixtures.DecodedOriginTwins do
  @moduledoc """
  The twins, each reported as before: chunk bytes on one path and a file's
  on the other, a private decoder another caller hands a caller's bytes,
  a build file named by a caller (`../` climbs out), an exported decoder a
  local caller hands chunk bytes, and a fun's parameter, which whatever
  runs the fun hands it.
  """

  def either(beam, path, from_beam?) do
    bytes =
      if from_beam? do
        {:ok, {_module, [{~c"Attr", chunk}]}} = :beam_lib.chunks(beam, [~c"Attr"])
        chunk
      else
        File.read!(path)
      end

    :erlang.binary_to_term(bytes)
  end

  def attributes(beam) do
    {:ok, {_module, [{~c"Attr", chunk}]}} = :beam_lib.chunks(beam, [~c"Attr"])
    decode(chunk)
  end

  def load(bytes), do: decode(bytes)

  defp decode(bytes), do: :erlang.binary_to_term(bytes)

  def named(name),
    do: :erlang.binary_to_term(File.read!(Path.join(Mix.Project.manifest_path(), name)))

  def chunk_terms(beam) do
    {:ok, {_module, [{~c"Attr", chunk}]}} = :beam_lib.chunks(beam, [~c"Attr"])
    exported_decode(chunk)
  end

  def exported_decode(bytes), do: :erlang.binary_to_term(bytes)

  def through_fun(beam, run) do
    {:ok, {_module, [{~c"Attr", chunk}]}} = :beam_lib.chunks(beam, [~c"Attr"])
    run.(chunk, fn bytes -> :erlang.binary_to_term(bytes) end)
  end
end
