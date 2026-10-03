defmodule Argus.Analyses.UnsafeInput.PathTraversal do
  @moduledoc "Findings for upload filenames used as filesystem paths."
  alias Argus.Findings

  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations do
    [
      %{
        name: :upload_filename_path_traversal,
        fields: [
          {:id, :symbol, "filesystem operation"},
          {:func, :symbol, "owning function"},
          {:api, :symbol, "filesystem API"},
          {:source, :symbol, "upload callback filename source"},
          {:shape, :symbol, "joined or filename"}
        ],
        key: [:id, :source],
        doc:
          "A client upload filename controls a filesystem path without a final file-component proof."
      }
    ]
  end

  @spec finding(atom(), [String.t()]) :: Findings.attrs()
  def finding(:upload_filename_path_traversal, [id, func, api, _source, shape]) do
    detail =
      if shape == "joined",
        do: "Joining this filename to a directory does not prevent path traversal. ",
        else: "The filename can contain path separators or parent components. "

    Findings.new(
      :error,
      "Upload filename controls a filesystem path",
      "#{func} passes a path derived from an upload entry's client_name to #{api}. " <>
        detail <>
        "The browser supplies this filename, independently of the server's temporary upload path.",
      at: Findings.at_instr(id),
      at_label: "filesystem path contains an upload filename",
      help: [
        "generate a server-side filename, or strip path components before using the name as the final file component",
        "reject dot and dot-dot for operations that accept directories; lexical normalization alone is not containment",
        "where existing paths can contain symlinks, enforce containment when opening or changing the file"
      ]
    )
  end
end
