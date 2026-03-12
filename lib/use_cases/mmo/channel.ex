defmodule MMO.Channel do
  @moduledoc """
  MMO channel join handlers and socket assignment logic.

  Maps channel topics to socket assigns that determine data scoping.
  """

  @behaviour SyncServer.ChannelHandler

  require Logger

  @impl true
  def join("sync:user:" <> user_id, %{"client_id" => client_id} = params) do
    Logger.info("Client #{client_id} joining user channel for user #{user_id}")

    %{
      client_id: client_id,
      user_id: user_id,
      channel_type: :user,
      metadata: params["metadata"] || %{}
    }
  end

  def join("sync:guild:" <> guild_id, %{"client_id" => client_id} = params) do
    Logger.info("Client #{client_id} joining guild channel: #{guild_id}")

    %{
      client_id: client_id,
      guild_id: guild_id,
      channel_type: :guild,
      metadata: params["metadata"] || %{}
    }
  end

  def join("sync:world", %{"client_id" => client_id} = params) do
    Logger.info("Client #{client_id} joining world channel")

    %{
      client_id: client_id,
      channel_type: :world,
      metadata: params["metadata"] || %{}
    }
  end

  def join("sync:zone:" <> zone_id, %{"client_id" => client_id} = params) do
    Logger.info("Client #{client_id} joining zone channel: #{zone_id}")

    %{
      client_id: client_id,
      zone_id: zone_id,
      channel_type: :zone,
      metadata: params["metadata"] || %{}
    }
  end

  def join("sync:party:" <> party_id, %{"client_id" => client_id} = params) do
    Logger.info("Client #{client_id} joining party channel: #{party_id}")

    %{
      client_id: client_id,
      party_id: party_id,
      channel_type: :party,
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
  def tables_for_channel(%{channel_type: :user}), do: ["users", "tasks"]
  def tables_for_channel(%{channel_type: :guild}), do: ["guild_chat"]
  def tables_for_channel(%{channel_type: :zone}), do: ["player_positions"]
  def tables_for_channel(%{channel_type: :world}), do: ["world_events"]
  def tables_for_channel(%{channel_type: :party}), do: []
  def tables_for_channel(_), do: []
end
