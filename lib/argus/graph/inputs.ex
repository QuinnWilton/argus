defmodule Argus.Graph.Inputs do
  @moduledoc """
  What the query graph (`Argus.Graph`) is a function of: the inputs a
  frontend sets before it demands anything, and nothing a query computes.

    * `program` (a program's id, any term) — the beams the program is
      made of, as a sorted list of their keys.
    * `beam` (a beam's key: the absolute path of its file, or `{:data,
      digest}` for one held in memory) — `%{hash: digest}`, the SHA-256
      of the beam without the chunks extraction never reads
      (`Roux.Code.canonical_beam/1`), and `data:` the bytes for one held
      in memory. A recompiled beam that only refreshed its type checker
      table sets an equal value, and advances nothing.
    * `project_root` (`:all`) — where a beam whose recorded source path
      belongs to another machine finds its source.
    * `specs_source` (`:all`) — where the specs of the modules a program
      calls are read from (`Argus.Specs.Source`: the project's own ebins
      and the installed OTP), or nil for the VM's code path (an in-VM
      caller analyzing the VM's own code).
    * `code_index` (`:all`) — each directory the specs are read from
      (the source's, or the code path's) outside OTP and Elixir, and
      what the specs read from there are named by (`app_code`):
      `%{dir => name}`.
    * `app_code` (a `code_index` name) — a digest of the stamps (size,
      modification time, inode) of every beam in that directory: it
      moves when a beam there is rebuilt, and a reader of a module's
      specs there looks at them again (`Argus.Graph.Reads`).
    * `solver` (`:all`) — `%{version: digest, timeout: ms, workers: n | :auto}`:
      the FlowLog toolchain's sources' digest, a commit's timeout and an
      engine's workers.
    * `dl_tree` (a directory) — each Datalog file under it and its
      content's digest: what a program is read from
      (`Argus.Graph.Programs`).
    * `priors` (`{program, relation}`) — a layer-3 relation's rows as
      the text an engine reads, empty when priors are off.

  Durability: `program`, `beam` and `priors` move with the project and
  are `:medium`; the rest move with the toolchain and are `:high`, so a
  project edit never walks what only they reach. Nothing here is `:low`:
  durability propagates as the minimum, and a `:low` entry is never
  kept in a manifest.
  """

  use Roux.Query

  definput(:program, durability: :medium)
  definput(:beam, durability: :medium)
  definput(:priors, durability: :medium)
  definput(:project_root, durability: :high)
  definput(:specs_source, durability: :high)
  definput(:code_index, durability: :high)
  definput(:app_code, durability: :high)
  definput(:solver, durability: :high)
  definput(:dl_tree, durability: :high)
end
