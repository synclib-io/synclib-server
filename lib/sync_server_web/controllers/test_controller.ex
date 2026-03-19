defmodule SyncServerWeb.TestController do
  use SyncServerWeb, :controller

  def options(conn, _params), do: send_resp(conn, 204, "")

  def delete_all_items(conn, _params) do
    SyncServer.Repo.query!("DELETE FROM items")
    json(conn, %{status: "ok", message: "All items deleted"})
  end
end
