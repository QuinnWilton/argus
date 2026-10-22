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
        name: :decoded_origin,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the binary_to_term call"},
          {:func, :func_id, "containing function ID"},
          {:origin, :symbol,
           "artifact: a BEAM file's chunks or object code; build: a file under the " <>
             "project's build directories; file: a file at a path literals spell"},
          {:path, :symbol,
           "for file, the path as the code spells it, empty when no one literal does; " <>
             "else empty"}
        ],
        doc: """
        The bytes a `binary_to_term/1,2` call decodes come, on every path the module \
        shows, from a BEAM file's chunks or object code (`:beam_lib`, \
        `:code.get_object_code/1`), from a file whose path is made of the project's \
        own build directories and literals alone, or from a file whose path is made of \
        literals alone (`Argus.Extractors.DecodedOrigin`). A parameter of a function \
        callers outside the module can run, and a value whose making the walk does not \
        see, is none of them.
        """
      },
      %{
        name: :option_value,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the atom-creating call"},
          {:func, :func_id, "containing function ID"}
        ],
        doc: """
        The string an atom is made of at `id` is, on every reaching path, an option's \
        value: the second element of a list's pair whose first element the function \
        compares to literal atoms, or what a keyed lookup answers under a literal atom \
        key (`Argus.Extractors.OptionValues`).
        """
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
        literal on every path, or to `mix` with a literal task that runs no code its \
        arguments name, through the module's local helpers' returns and a private \
        function's callers (`Argus.Extractor.Argv`). Covers only calls the function's \
        own body could not show fixed, which `code_execution` keeps.
        """
      },
      %{
        name: :command_data_args,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the System.cmd call"},
          {:func, :func_id, "containing function ID"}
        ],
        doc: """
        A `System.cmd` call to a literal POSIX shell handed `-c` and a literal script, \
        on every path through the module's local helpers and a private function's \
        callers, that uses the positional parameters after it only as quoted \
        arguments of programs that do not run their arguments \
        (`Argus.Extractor.ShellScript`): the rest of the argument list is data, \
        not code.
        """
      },
      %{
        name: :verification_gated,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the binary_to_term call"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: """
        The `binary_to_term` call is reached only when a cryptographic verification \
        the function performs succeeds: a boolean verify or constant-time compare \
        (`Plug.Crypto.secure_compare/2`, `:crypto.hash_equals/2`, `:crypto.verify`, \
        `:public_key.verify`) tested against `true`/`false`, or a MAC/HMAC digest \
        (`:crypto.mac`, `:crypto.hmac`) compared for equality against the supplied \
        digest, with the decode on the accepting edge (`Argus.Extractors.VerificationGate`). \
        A gated decode is re-ranked below an ungated one, never dropped: the secret's \
        strength and whether the gate covers these exact bytes stay unproven.
        """
      }
    ])
  end
end
