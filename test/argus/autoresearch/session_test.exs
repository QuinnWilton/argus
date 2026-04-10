defmodule Argus.Autoresearch.SessionTest do
  use ExUnit.Case, async: true

  alias Argus.Autoresearch.Session

  @moduletag :tmp_dir

  describe "append/2" do
    test "creates the session directory and writes a jsonl line", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")

      assert :ok =
               Session.append(%{event: :measure, duration_s: 42, projects: ["plug"]}, dir)

      assert File.exists?(Session.log_path(dir))

      content = File.read!(Session.log_path(dir))
      assert String.trim_trailing(content) |> String.ends_with?("}")

      [decoded] = content |> String.trim() |> String.split("\n") |> Enum.map(&:json.decode/1)
      assert decoded["event"] == "measure"
      assert decoded["duration_s"] == 42
      assert decoded["projects"] == ["plug"]
      # Timestamp is automatic.
      assert is_binary(decoded["t"])
    end

    test "atoms in values are stringified", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")

      assert :ok = Session.append(%{event: :checks, result: :pass}, dir)

      [event] = Session.recent(1, dir)
      assert event["result"] == "pass"
      assert event["event"] == "checks"
    end

    test "nested atoms in map values are stringified", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")

      assert :ok =
               Session.append(
                 %{event: :attempt_end, result: :accepted, delta: %{category: "foo", sign: :neg}},
                 dir
               )

      [event] = Session.recent(1, dir)
      assert event["delta"]["sign"] == "neg"
      assert event["delta"]["category"] == "foo"
    end

    test "preserves existing timestamp if provided", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")
      ts = "2026-04-09T14:00:00Z"

      assert :ok = Session.append(%{event: :note, t: ts, text: "hello"}, dir)

      [event] = Session.recent(1, dir)
      assert event["t"] == ts
    end

    test "appends (not overwrites) on repeated calls", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")

      assert :ok = Session.append(%{event: :measure}, dir)
      assert :ok = Session.append(%{event: :rank}, dir)
      assert :ok = Session.append(%{event: :checks, result: :pass}, dir)

      assert length(Session.all(dir)) == 3
    end
  end

  describe "recent/2 and all/1" do
    test "returns [] when the log doesn't exist", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")
      assert Session.recent(10, dir) == []
      assert Session.all(dir) == []
    end

    test "recent returns most-recent-first, limited to count", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")

      for i <- 1..5 do
        Session.append(%{event: :note, text: "n#{i}"}, dir)
      end

      recent = Session.recent(3, dir)
      assert length(recent) == 3
      assert Enum.map(recent, & &1["text"]) == ["n5", "n4", "n3"]
    end

    test "all returns in chronological order", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")

      for i <- 1..3 do
        Session.append(%{event: :note, text: "n#{i}"}, dir)
      end

      assert Enum.map(Session.all(dir), & &1["text"]) == ["n1", "n2", "n3"]
    end

    test "skips malformed lines gracefully", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")
      File.mkdir_p!(dir)

      File.write!(
        Session.log_path(dir),
        ~s({"event":"measure","t":"ts"}\nnot valid json\n{"event":"rank","t":"ts"}\n)
      )

      events = Session.all(dir)
      assert length(events) == 2
      assert Enum.map(events, & &1["event"]) == ["measure", "rank"]
    end
  end

  describe "last_of/2" do
    test "returns the most recent event of a given type", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")

      Session.append(%{event: :measure, n: 1}, dir)
      Session.append(%{event: :checks}, dir)
      Session.append(%{event: :measure, n: 2}, dir)
      Session.append(%{event: :rank}, dir)

      assert %{"n" => 2} = Session.last_of(:measure, dir)
    end

    test "returns nil when no matching event exists", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")
      Session.append(%{event: :measure}, dir)
      assert nil == Session.last_of(:baseline_promoted, dir)
    end
  end

  describe "clear/1" do
    test "removes the log file if it exists", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")

      Session.append(%{event: :measure}, dir)
      assert File.exists?(Session.log_path(dir))

      assert :ok = Session.clear(dir)
      refute File.exists?(Session.log_path(dir))
    end

    test "is a no-op when log doesn't exist", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "session")
      assert :ok = Session.clear(dir)
    end
  end
end
