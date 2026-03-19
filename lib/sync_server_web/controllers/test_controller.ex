defmodule SyncServerWeb.TestController do
  use SyncServerWeb, :controller

  def delete_all_items(conn, _params) do
    SyncServer.Repo.query!("DELETE FROM items")
    json(conn, %{status: "ok", message: "All items deleted"})
  end
end
