defmodule Argus.Schema.UnsafeInput do
  @moduledoc """
  Layer-2 facts for input converted into atoms, terms, or executable code. Exposed \
  through `Argus.Schema`.
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
        A decompression call returning its entire output without a size bound: \
        `:zlib.gunzip/1`, `unzip/1`, `uncompress/1`, or `inflate/2,3`. Excludes \
        bounded-chunk APIs `safeInflate/2` and `inflateChunk/1,2`.
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
      },
      %{
        name: :command_fixed,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the System.cmd call"},
          {:func, :func_id, "containing function ID"}
        ],
        doc: """
        A `System.cmd` call to a literal shell or interpreter whose arguments are \
        literal on every path, through the module's local helpers' returns \
        (`Argus.Extractor.Argv`). Covers only calls the function's own body could not \
        show fixed, which `code_execution` keeps.
        """
      }
    ])
  end
end
