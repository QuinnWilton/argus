defmodule Argus.MissingRelationError do
  @moduledoc """
  A relation's file a reader needs is not there.

  Every writer of a relation file leaves one for each relation it is
  responsible for, empty when the relation has no rows:
  `Argus.Pipeline.run/3` for every schema relation, Souffle for every
  relation a program outputs, a kept solve for each file its manifest
  names. So an absent file is never an empty relation. It is a
  directory changed under its reader, or one that is not what the
  reader was handed, and a reader that took it for no rows would drop
  findings without a word. This error names the file and the relation
  instead.

  Returned as `{:error, %Argus.MissingRelationError{}}` where a reader
  answers with tagged tuples, raised where it answers with a value.
  """

  defexception [:relation, :path, :reason]

  @typedoc """
  The relation (its name, as its file is named), the file, and why it
  could not be read (`:enoent` when it is not there).
  """
  @type t :: %__MODULE__{
          relation: String.t(),
          path: Path.t(),
          reason: File.posix() | :badarg | :terminated | :system_limit
        }

  @impl true
  def message(%__MODULE__{relation: relation, path: path, reason: reason}) do
    "the #{relation} relation's file could not be read (#{:file.format_error(reason)}): " <>
      "#{path}. Every writer of a facts or output directory leaves a file for each of its " <>
      "relations, empty when it has none, so an absent one is not read as no rows: the " <>
      "directory changed under its reader, or is not the one it was handed"
  end
end
