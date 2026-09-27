defmodule Argus.Dl do
  @moduledoc """
  Where argus's Datalog rules are on disk: `root/0` is the `dl/`
  directory every program, stage and include is read from.

  In a Mix build that is the application's `priv/dl`. An escript has no
  priv directory — its code is an archive, and Souffle reads its
  programs and their `.include`s from files — so the rules travel inside
  the code (`Argus.Dl.Embedded`) and are unpacked, once per tree of
  rules, under the blob store (`Argus.Dirs.dl/0`): `<store>/dl/<digest
  of the tree>/`. The unpacking is atomic (a directory of its own,
  renamed into place), so runs racing to unpack the same tree agree, and
  a tree once unpacked is never written again: another version of the
  rules is another directory.
  """

  alias Argus.Dl.Embedded

  @doc """
  The directory of argus's Datalog rules: the one the `:dl_root`
  application variable names (a copy of the tree a test edits a rule
  in, in a VM of its own), else the shipped rules (`shipped/0`).
  """
  @spec root() :: Path.t()
  def root do
    case Application.get_env(:panoptes, :dl_root) do
      nil -> shipped()
      root -> root
    end
  end

  @doc """
  The rules argus ships: the application's priv/dl, or the tree the code
  carries, unpacked. Memoized for the VM.
  """
  @spec shipped() :: Path.t()
  def shipped do
    case :persistent_term.get({__MODULE__, :shipped}, nil) do
      nil ->
        root = priv_root() || Embedded.unpack!(Argus.Dirs.dl())
        :persistent_term.put({__MODULE__, :shipped}, root)
        root

      root ->
        root
    end
  end

  @doc "A file under the rules' directory: `path` relative to `root/0`."
  @spec path(Path.t()) :: Path.t()
  def path(relative), do: Path.join(root(), relative)

  # The application's own priv/dl, when it is a directory on disk that
  # holds the rules (it is not inside an escript's archive).
  defp priv_root do
    with dir when is_list(dir) <- :code.priv_dir(:panoptes),
         root = Path.join(List.to_string(dir), "dl"),
         true <- File.regular?(Path.join(root, "base.dl")) do
      root
    else
      _ -> nil
    end
  end
end
