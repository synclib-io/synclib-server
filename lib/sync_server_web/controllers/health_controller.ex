defmodule SyncServerWeb.HealthController do
  use SyncServerWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", version: 1})
  end
end
