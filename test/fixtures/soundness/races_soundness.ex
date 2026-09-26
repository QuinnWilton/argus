defmodule Probe.R2.G7.Advance do
  # A job's stage advanced by whichever worker gets there: the stage read
  # is handed to a pure helper that picks the next stage by pattern (the
  # value is chosen by the read, not made of it). Two racers both read
  # :queued and both write :running; serially it would be :done.
  def start, do: :ets.new(:stages, [:named_table, :public])

  def advance(id) do
    case :ets.lookup(:stages, id) do
      [{^id, stage}] -> :ets.insert(:stages, {id, next(stage)})
      [] -> :missing
    end
  end

  defp next(:queued), do: :running
  defp next(:running), do: :done
  defp next(:done), do: :done
end

defmodule Probe.R2.G7.MnesiaAdvance do
  # The same over Mnesia with dirty ops.
  def advance(id) do
    case :mnesia.dirty_read({:stages, id}) do
      [{:stages, ^id, stage}] -> :mnesia.dirty_write({:stages, id, next(stage)})
      [] -> :missing
    end
  end

  def put(id), do: :mnesia.dirty_write({:stages, id, :queued})

  defp next(:queued), do: :running
  defp next(:running), do: :done
  defp next(:done), do: :done
end

defmodule Probe.R2.G7.ToggleHelper do
  # A feature flag any process flips: the row's state is handed to a pure
  # helper that returns the next state, chosen by (not made of) the state
  # it is handed. Two racers both read :on and both write :off: one flip
  # is lost (serially the flag would be back at :on).
  def start, do: :ets.new(:flags, [:named_table, :public])

  def flip(name) do
    case :ets.lookup(:flags, name) do
      [{^name, state}] -> :ets.insert(:flags, {name, opposite(state)})
      [] -> :ets.insert(:flags, {name, :on})
    end
  end

  defp opposite(:on), do: :off
  defp opposite(:off), do: :on
end

defmodule S2c.Races.AdvanceInline do
  # The stage transition written inline: the read's value decides which
  # literal is written. Two racers both read :queued, both write :running.
  def start, do: :ets.new(:s2c_stages_inline, [:named_table, :public])

  def advance(id) do
    case :ets.lookup(:s2c_stages_inline, id) do
      [{^id, :queued}] -> :ets.insert(:s2c_stages_inline, {id, :running})
      [{^id, :running}] -> :ets.insert(:s2c_stages_inline, {id, :done})
      _ -> :ok
    end
  end
end

defmodule S2c.Races.AdvanceTwoDeep do
  # next/1 hands the stage to a second helper that picks.
  def start, do: :ets.new(:s2c_stages_deep, [:named_table, :public])

  def advance(id) do
    case :ets.lookup(:s2c_stages_deep, id) do
      [{^id, stage}] -> :ets.insert(:s2c_stages_deep, {id, next(stage)})
      [] -> :missing
    end
  end

  defp next(stage), do: step(stage)
  defp step(:queued), do: :running
  defp step(:running), do: :done
  defp step(:done), do: :done
end

defmodule S2c.Races.Stages do
  def next(:queued), do: :running
  def next(:running), do: :done
  def next(:done), do: :done
end

defmodule S2c.Races.AdvanceRemote do
  # The picking helper in another module.
  def start, do: :ets.new(:s2c_stages_remote, [:named_table, :public])

  def advance(id) do
    case :ets.lookup(:s2c_stages_remote, id) do
      [{^id, stage}] -> :ets.insert(:s2c_stages_remote, {id, S2c.Races.Stages.next(stage)})
      [] -> :missing
    end
  end
end

defmodule S2c.Races.AdvanceVar do
  # The picked stage bound first, then written in a record-shaped row.
  def start, do: :ets.new(:s2c_stages_var, [:named_table, :public])

  def advance(id) do
    case :ets.lookup(:s2c_stages_var, id) do
      [{^id, stage, owner}] ->
        new = pick(stage)
        :ets.insert(:s2c_stages_var, {id, new, owner})

      [] ->
        :missing
    end
  end

  defp pick(:queued), do: :running
  defp pick(_), do: :done
end
