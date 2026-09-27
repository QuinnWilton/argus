defmodule Argus.Schema.UnsafeInput do
  @moduledoc """
  Where outside input can become an atom, a term or code.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :unsafe_atom_creation,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:api, :symbol, "API name (e.g. String.to_atom/1)"}
        ],
        doc: "Unsafe atom creation from dynamic input."
      },
      %{
        name: :unsafe_deserialization,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:api, :symbol, "API name"},
          {:safety, :symbol, "safe or unsafe"}
        ],
        doc: "Binary-to-term deserialization call with safety classification."
      },
      %{
        name: :unsafe_decompression,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:api, :symbol, "API name (e.g. :zlib.gunzip/1)"},
          {:data_pos, :number, "the argument position of the compressed data"}
        ],
        doc: """
        A one-shot decompression: `:zlib.gunzip/1`, `unzip/1`, \
        `uncompress/1` or `inflate/2,3`, which return the whole output of \
        their input with no bound on its size (a few hundred bytes of \
        layered gzip inflate to gigabytes: Bandit's and Tesla's advisories). \
        The streaming `safeInflate/2` and `inflateChunk/1,2`, which hand \
        back one bounded chunk at a time, are not rows.
        """
      },
      %{
        name: :code_execution,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:api, :symbol, "API name (e.g. Code.eval_string/1)"}
        ],
        doc: "Dynamic code execution or OS command call."
      }
    ])
  end
end
