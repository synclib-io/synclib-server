defmodule SyncServer.SetupTriggersTest do
  use SyncServer.DataCase

  test "insert assigns a seqnum" do
    Repo.query!("INSERT INTO items (id, room_id, last_modified_ms) VALUES ('i1', 'r1', 1000)")
    %{rows: [[seqnum]]} = Repo.query!("SELECT seqnum FROM items WHERE id = 'i1'")
    assert is_integer(seqnum) and seqnum > 0
  end

  test "real update bumps seqnum" do
    Repo.query!("INSERT INTO items (id, room_id, last_modified_ms) VALUES ('i2', 'r1', 1000)")
    %{rows: [[seq1]]} = Repo.query!("SELECT seqnum FROM items WHERE id = 'i2'")

    Repo.query!("UPDATE items SET last_modified_ms = 2000 WHERE id = 'i2'")
    %{rows: [[seq2]]} = Repo.query!("SELECT seqnum FROM items WHERE id = 'i2'")

    assert seq2 > seq1
  end

  test "no-op update does NOT bump seqnum" do
    Repo.query!("INSERT INTO items (id, room_id, last_modified_ms) VALUES ('i3', 'r1', 1000)")
    %{rows: [[seq1]]} = Repo.query!("SELECT seqnum FROM items WHERE id = 'i3'")

    # Update with identical values — trigger should detect no change
    Repo.query!("UPDATE items SET room_id = 'r1', last_modified_ms = 1000 WHERE id = 'i3'")
    %{rows: [[seq2]]} = Repo.query!("SELECT seqnum FROM items WHERE id = 'i3'")

    assert seq2 == seq1
  end
end
