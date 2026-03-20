defmodule SyncServerWeb.AckRowHashTest do
  @moduledoc """
  Integration tests verifying that ACK and broadcast messages include
  the server-computed row_hash from pg_synclib_hash.

  Tests are skipped if pg_synclib_hash extension is not installed.
  """

  use SyncServerWeb.ChannelCase

  defp extension_available? do
    case Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'pg_synclib_hash'") do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  setup do
    socket = socket(SyncServerWeb.UserSocket, "user1", %{client_id: "ack-test-client"})
    {:ok, _reply, socket} = subscribe_and_join(socket, SyncServerWeb.SyncChannel,
      "sync:room:ack-room", %{"client_id" => "ack-test-client", "user_id" => "user1"})

    %{socket: socket}
  end

  describe "changes_batch ACK includes row_hash" do
    test "insert returns row_hash in pushed ack", %{socket: socket} do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      now = System.system_time(:millisecond)

      ref = push(socket, "changes_batch", %{
        "changes" => [
          %{
            "table" => "items",
            "operation" => "insert",
            "row_id" => "ack-item-1",
            "seqnum" => 1,
            "data" => %{"room_id" => "ack-room", "last_modified_ms" => now}
          }
        ]
      })

      assert_reply ref, :ok, %{status: "all_applied"}

      # The ack is pushed as a separate message (not in the reply)
      assert_push "ack", ack
      assert ack.success == true
      assert ack.seqnum == 1
      assert is_binary(ack.row_hash)
      assert String.length(ack.row_hash) == 64

      # Verify the stored row_hash matches what was returned in ACK
      %{rows: [[db_hash]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'ack-item-1'")
      assert ack.row_hash == db_hash
    end

    test "update returns updated row_hash in pushed ack", %{socket: socket} do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      now = System.system_time(:millisecond)

      # First insert
      ref1 = push(socket, "changes_batch", %{
        "changes" => [
          %{
            "table" => "items",
            "operation" => "insert",
            "row_id" => "ack-item-2",
            "seqnum" => 10,
            "data" => %{"room_id" => "ack-room", "last_modified_ms" => now}
          }
        ]
      })
      assert_reply ref1, :ok, _
      assert_push "ack", ack1
      hash_after_insert = ack1.row_hash

      # Then update
      ref2 = push(socket, "changes_batch", %{
        "changes" => [
          %{
            "table" => "items",
            "operation" => "update",
            "row_id" => "ack-item-2",
            "seqnum" => 11,
            "data" => %{"room_id" => "ack-room", "last_modified_ms" => now + 5000}
          }
        ]
      })
      assert_reply ref2, :ok, _
      assert_push "ack", ack2
      hash_after_update = ack2.row_hash

      # Hash should change after update
      assert is_binary(hash_after_update)
      assert String.length(hash_after_update) == 64
      assert hash_after_insert != hash_after_update

      # DB should match ACK
      %{rows: [[db_hash]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'ack-item-2'")
      assert hash_after_update == db_hash
    end
  end

  describe "broadcast includes row_hash" do
    test "change broadcast to other clients includes row_hash", %{socket: socket} do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      # Join a second client on the same room to receive broadcasts
      socket2 = socket(SyncServerWeb.UserSocket, "user2", %{client_id: "ack-test-client-2"})
      {:ok, _reply2, _socket2} = subscribe_and_join(socket2, SyncServerWeb.SyncChannel,
        "sync:room:ack-room", %{"client_id" => "ack-test-client-2", "user_id" => "user2"})

      now = System.system_time(:millisecond)

      ref = push(socket, "changes_batch", %{
        "changes" => [
          %{
            "table" => "items",
            "operation" => "insert",
            "row_id" => "broadcast-item-1",
            "seqnum" => 20,
            "data" => %{"room_id" => "ack-room", "last_modified_ms" => now}
          }
        ]
      })

      assert_reply ref, :ok, _

      # The broadcast should arrive on the topic with row_hash in data
      assert_broadcast "change", broadcast_payload

      data = broadcast_payload["data"]
      assert is_binary(data["row_hash"])
      assert String.length(data["row_hash"]) == 64
    end
  end
end
