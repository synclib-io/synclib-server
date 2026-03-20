defmodule SyncServer.ChangeHandlerTest do
  use SyncServer.DataCase

  describe "issue #22: get_schema_for_table returns nil for unknown tables" do
    test "returns nil for unknown table name" do
      schema = Test.ChangeHandler.get_schema_for_table("nonexistent_table")
      # Fix: returns nil instead of defaulting to Item
      assert is_nil(schema)
    end

    test "returns Item schema for known table" do
      schema = Test.ChangeHandler.get_schema_for_table("items")
      assert schema == Test.Schema.Item
    end
  end

  describe "issue #21: LWW conflict resolution on insert" do
    test "newer insert overwrites older data" do
      assigns = %{room_id: "room1", channel_type: :room, client_id: "c1"}
      now = System.system_time(:millisecond)

      {:ok, _} = Test.ChangeHandler.apply_change(
        "items", "insert", "lww-test",
        %{"room_id" => "room1", "last_modified_ms" => now},
        assigns
      )

      # Newer timestamp wins
      {:ok, record} = Test.ChangeHandler.apply_change(
        "items", "insert", "lww-test",
        %{"room_id" => "room1", "last_modified_ms" => now + 5000},
        assigns
      )

      assert record.last_modified_ms == now + 5000
    end

    test "older insert is rejected, newer data preserved" do
      assigns = %{room_id: "room1", channel_type: :room, client_id: "c1"}
      now = System.system_time(:millisecond)

      # Insert with newer timestamp first
      {:ok, _} = Test.ChangeHandler.apply_change(
        "items", "insert", "lww-test2",
        %{"room_id" => "room1", "last_modified_ms" => now + 5000},
        assigns
      )

      # Older timestamp is rejected — existing data preserved
      {:ok, record} = Test.ChangeHandler.apply_change(
        "items", "insert", "lww-test2",
        %{"room_id" => "room1", "last_modified_ms" => now},
        assigns
      )

      # Fix: LWW check preserves the newer data
      assert record.last_modified_ms == now + 5000
    end
  end
end
