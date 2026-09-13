defmodule Argus.SchemaVersionTest do
  @moduledoc """
  Guards the link between the schema and the number that describes it.

  `Argus.Schema.version/0` is what downstream tools key on: scry and
  planchette fold it into the environment fingerprint that invalidates
  their extraction memos, and encore stamps it into every golden. That
  only works if the version actually moves when the schema does — and it
  once sat at 16 through ten schema-changing commits, two of which named
  the right number in the subject line and never edited the attribute.

  So this pins the shape as well as the number. Any relation added or
  removed, any field renamed, retyped, or moved, changes the digest and
  fails this test until someone bumps the version on purpose.

  What it cannot check is the last clause of the version docstring — "or a
  field's meaning changes". Redefining what a column holds without touching
  its name or type is invisible here, and still requires a deliberate bump.
  """

  use ExUnit.Case, async: true

  alias Argus.Schema

  # Bump BOTH when the schema changes. The digest covers name, layer, and
  # each field's name, type and position; the doc strings are deliberately
  # excluded so that improving a description is not a schema change.
  @version 29
  @shape_digest "870BF272DF9334E32870343A8D3BF0B6304231A4590C6CB55BD67D9DBC3E8451"

  defp shape_digest do
    Schema.all()
    |> Enum.map(fn rel ->
      {rel.name, rel.layer, Enum.map(rel.fields, fn {name, kind, _doc} -> {name, kind} end)}
    end)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16()
  end

  test "the schema version tracks the schema" do
    actual = shape_digest()

    assert Schema.version() == @version and actual == @shape_digest, """
    The schema and the version that describes it have diverged.

      expected version: #{@version}, got #{Schema.version()}
      expected digest:  #{@shape_digest}
      actual digest:    #{actual}

    If you changed the relation set — added or removed a relation, renamed
    a field, changed a field's type, or moved one — then bump
    @schema_version in lib/argus/schema.ex and update @version and
    @shape_digest here to match, and record the change in CHANGELOG.md —
    consumers that read positional columns (gloss, lowdown, scry) find out
    about a bump from that entry, not from a compile error.
    """
  end

  test "every relation the digest covers is well-formed" do
    for rel <- Schema.all() do
      assert is_atom(rel.name), "relation name must be an atom: #{inspect(rel)}"
      assert rel.layer in [1, 2], "#{rel.name} has layer #{inspect(rel.layer)}, expected 1 or 2"
      assert rel.fields != [], "#{rel.name} declares no fields"

      for {name, kind, doc} <- rel.fields do
        assert is_atom(name), "#{rel.name} has a non-atom field name: #{inspect(name)}"
        assert is_atom(kind), "#{rel.name}.#{name} has a non-atom kind: #{inspect(kind)}"
        assert is_binary(doc) and doc != "", "#{rel.name}.#{name} has no doc"
      end
    end
  end

  test "relation names are unique" do
    names = Enum.map(Schema.all(), & &1.name)

    duplicates = names -- Enum.uniq(names)

    assert duplicates == [],
           "a duplicate relation name shadows the earlier definition in " <>
             "@relations_by_name, so one of them is unreachable: #{inspect(duplicates)}"
  end
end
