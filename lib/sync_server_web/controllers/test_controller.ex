defmodule SyncServerWeb.TestController do
  use SyncServerWeb, :controller

  alias SyncServer.Repo

  def options(conn, _params), do: send_resp(conn, 204, "")

  def get_item(conn, %{"id" => id}) do
    case Repo.query("SELECT id, last_modified_ms, row_hash, seqnum FROM items WHERE id = $1", [id]) do
      {:ok, %{rows: [row], columns: cols}} ->
        item = Enum.zip(cols, row) |> Map.new()
        json(conn, %{status: "ok", item: item})

      _ ->
        conn |> put_status(404) |> json(%{error: "Item not found"})
    end
  end

  def delete_all_items(conn, _params) do
    Repo.query!("DELETE FROM items")
    json(conn, %{status: "ok", message: "All items deleted"})
  end

  @doc """
  Update an item directly in Postgres, bypassing sync.

  Only disables the seqnum trigger so that:
    - seqnum stays unchanged → normal sync won't detect the change
    - row_hash trigger (zzz_synclib_row_hash) still fires → row_hash is
      correctly recomputed for the new data

  This creates realistic data drift that only merkle verification can detect.
  """
  def update_item(conn, %{"id" => id} = params) do
    sets =
      params
      |> Map.drop(["id"])
      |> Enum.map(fn {k, v} -> "#{k} = #{quote_value(v)}" end)
      |> Enum.join(", ")

    if sets == "" do
      conn |> put_status(400) |> json(%{error: "No fields to update"})
    else
      Repo.transaction(fn ->
        Repo.query!("ALTER TABLE items DISABLE TRIGGER items_seqnum_trigger")
        Repo.query!("UPDATE items SET #{sets} WHERE id = $1", [id])
        Repo.query!("ALTER TABLE items ENABLE TRIGGER items_seqnum_trigger")
      end)

      json(conn, %{status: "ok", message: "Item updated (seqnum trigger bypassed, hash recomputed)"})
    end
  end

  @doc """
  Delete an item directly in Postgres, bypassing sync AND triggers.

  The row is hard-deleted (not soft-deleted). Since triggers are disabled,
  seqnum doesn't change — only merkle verification can detect the missing row.
  """
  def delete_item(conn, %{"id" => id}) do
    Repo.transaction(fn ->
      Repo.query!("ALTER TABLE items DISABLE TRIGGER ALL")
      Repo.query!("DELETE FROM items WHERE id = $1", [id])
      Repo.query!("ALTER TABLE items ENABLE TRIGGER ALL")
    end)

    json(conn, %{status: "ok", message: "Item deleted (triggers bypassed)"})
  end

  defp quote_value(v) when is_binary(v), do: "'#{String.replace(v, "'", "''")}'"
  defp quote_value(v) when is_integer(v), do: Integer.to_string(v)
  defp quote_value(v) when is_float(v), do: Float.to_string(v)
  defp quote_value(nil), do: "NULL"
end
