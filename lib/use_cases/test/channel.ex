defmodule Test.Channel do
  @behaviour SyncServer.ChannelHandler

  require Logger

  @impl true
  def join("sync:room:" <> room_id, %{"client_id" => client_id} = params) do
    user_id = params["user_id"] || "anonymous"
    Logger.info("[Test] Client #{client_id} (user #{user_id}) joining room #{room_id}")

    %{
      client_id: client_id,
      room_id: room_id,
      user_id: user_id,
      channel_type: :room,
      metadata: params["metadata"] || %{}
    }
  end

  def join("sync:" <> _room, _params) do
    {:error, "client_id required"}
  end

  def join(_channel, _params) do
    {:error, "unknown channel"}
  end

  @impl true
  def tables_for_channel(%{channel_type: :room}), do: ["items"]
  def tables_for_channel(_), do: []
end
