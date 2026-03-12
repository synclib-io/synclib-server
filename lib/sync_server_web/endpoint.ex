defmodule SyncServerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :sync_server

  @session_options [
    store: :cookie,
    key: "_sync_server_key",
    signing_salt: "secret",
    same_site: "Lax"
  ]

  socket "/socket", SyncServerWeb.UserSocket,
    websocket: [check_origin: false],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :sync_server,
    gzip: false,
    only: SyncServerWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SyncServerWeb.Router
end
