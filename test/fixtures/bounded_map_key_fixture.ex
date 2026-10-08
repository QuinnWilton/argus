defmodule Argus.Test.Fixtures.BoundedMapKey do
  @moduledoc false
  # A key found in a literal map is one of the map's keys. Each safe shape
  # has a twin that makes the atom where the key is not known to be one.

  @child_boxes %{"stsd" => :sample_description, "stts" => :time_to_sample, "stsz" => :sizes}

  # ex_mp4's Stbl.do_parse/2: the atom is made on the `{:ok, _}` arm.
  def fetched(box, name) do
    case Map.fetch(@child_boxes, name) do
      {:ok, kind} -> Map.put(box, String.to_atom(name), kind)
      :error -> box
    end
  end

  def fetched_error_arm(box, name) do
    case Map.fetch(@child_boxes, name) do
      {:ok, kind} -> Map.put(box, :known, kind)
      :error -> Map.put(box, String.to_atom(name), nil)
    end
  end

  def fetched_with(name) do
    with {:ok, _kind} <- Map.fetch(@child_boxes, name), do: String.to_atom(name)
  end

  def fetched!(name) do
    _kind = Map.fetch!(@child_boxes, name)
    String.to_atom(name)
  end

  def has_key(name), do: if(Map.has_key?(@child_boxes, name), do: String.to_atom(name))

  def has_no_key(name),
    do: if(Map.has_key?(@child_boxes, name), do: nil, else: String.to_atom(name))

  def guarded(name) when is_map_key(@child_boxes, name), do: String.to_atom(name)

  # One of two literal maps: a key either holds is one of their keys.
  def either_map(flag, name) do
    map = if flag, do: @child_boxes, else: %{"moov" => :movie}
    if Map.has_key?(map, name), do: String.to_atom(name)
  end

  # A map the caller hands in holds whatever keys the caller put there.
  def caller_map(map, name) when is_map_key(map, name), do: String.to_atom(name)

  def caller_fetch(map, name) do
    case Map.fetch(map, name) do
      {:ok, _} -> String.to_atom(name)
      :error -> nil
    end
  end
end
