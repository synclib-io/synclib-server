defmodule SyncServer.ConnectionHandler do
  @moduledoc """
  Behaviour for handling client connect/disconnect events.

  Implement this for online/offline tracking, cleanup, or analytics.

  ## Example

      defmodule MyApp.ConnectionHandler do
        @behaviour SyncServer.ConnectionHandler
        require Logger

        @impl true
        def handle_connect(socket) do
          user_id = socket.assigns[:user_id]
          Logger.info("User \#{user_id} connected")
          :ok
        end

        @impl true
        def handle_disconnect(_reason, socket) do
          user_id = socket.assigns[:user_id]
          Logger.info("User \#{user_id} disconnected")
          :ok
        end
      end
  """

  @doc """
  Called after a client successfully joins a channel.
  """
  @callback handle_connect(socket :: Phoenix.Socket.t()) :: :ok

  @doc """
  Called when a client disconnects from a channel.
  """
  @callback handle_disconnect(reason :: any(), socket :: Phoenix.Socket.t()) :: :ok
end
