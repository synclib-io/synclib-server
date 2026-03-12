defmodule SyncServerWeb.UserSocket do
  use Phoenix.Socket
  require Logger

  alias SyncServer.Auth.JWTVerifier

  # Channels — sync channels for different scopes
  channel "sync:user:*", SyncServerWeb.SyncChannel
  channel "sync:world", SyncServerWeb.SyncChannel
  channel "sync:zone:*", SyncServerWeb.SyncChannel
  channel "sync:guild:*", SyncServerWeb.SyncChannel
  channel "sync:party:*", SyncServerWeb.SyncChannel

  @impl true
  def connect(%{"token" => token, "client_id" => client_id}, socket, _connect_info) do
    case JWTVerifier.verify_token(token, client_id) do
      {:ok, claims} ->
        Logger.info("Client #{client_id} authenticated successfully")
        socket = assign(socket, :client_id, client_id)
        socket = assign(socket, :claims, claims)
        {:ok, socket}

      {:error, reason} ->
        user_info = extract_token_subject(token)
        Logger.warning("Authentication failed for client #{client_id} (user: #{user_info}): #{inspect(reason)}")
        :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    Logger.warning("Connection attempt without required token/client_id")
    :error
  end

  # Extract the 'sub' claim from a JWT without verification (for logging purposes only)
  defp extract_token_subject(token) do
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"sub" => sub}} -> sub
              _ -> "unknown"
            end
          _ -> "unknown"
        end
      _ -> "unknown"
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.client_id}"
end
