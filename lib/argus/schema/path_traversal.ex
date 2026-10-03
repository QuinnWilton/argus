defmodule Argus.Schema.PathTraversal do
  @moduledoc "Upload filename provenance at filesystem path operations."

  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :upload_path_use,
        layer: 2,
        fields: [
          {:id, :symbol, "filesystem operation instruction"},
          {:func, :symbol, "owning function"},
          {:api, :symbol, "filesystem API"},
          {:source, :symbol, "specific upload callback filename field"},
          {:shape, :symbol, "joined or filename"}
        ],
        doc: """
        A filesystem path contains client_name from parameter one of a known \
        consume_uploaded_entries callback. Other fields, unrelated parameters and \
        arbitrary configurable paths do not create upload origins. The operation's \
        actual source/destination argument is retained while tracing the path.
        """
      },
      %{
        name: :upload_path_leaf_safe,
        layer: 2,
        fields: [
          {:id, :symbol, "filesystem operation instruction"},
          {:func, :symbol, "owning function"},
          {:source, :symbol, "same upload callback filename field"}
        ],
        doc: """
        Every modeled occurrence of this filename in this operation's path has \
        passed through basename and remains the final path component, with no \
        unknown reaching alternative. Only file-leaf operations qualify: a final \
        dot or dot-dot names a directory and those operations fail. This is not \
        a general path-containment or symlink proof, and does not clear operations \
        accepting directories, appended suffixes, or arbitrary path normalization.
        """
      }
    ])
  end
end
