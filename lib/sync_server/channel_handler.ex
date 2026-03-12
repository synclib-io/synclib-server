defmodule SyncServer.ChannelHandler do
  @moduledoc """
  Behaviour for handling channel join logic.

  Implement this to define how channel topics map to socket assigns.
  The returned assigns determine what data the client can access.

  ## Example

      defmodule MyApp.Channel do
        @behaviour SyncServer.ChannelHandler

        @impl true
        def join("sync:user:" <> user_id, %{"client_id" => client_id} = _params) do
          %{client_id: client_id, user_id: user_id, channel_type: :user}
        end

        def join(_channel, _params), do: {:error, "unknown channel"}
      end
  """

  @doc """
  Handle a channel join request.

  Returns a map of assigns to add to the socket, or `{:error, reason}`.

  ## Parameters
  - `channel_name` - The full channel topic (e.g., "sync:user:abc123")
  - `params` - Join parameters from the client (includes "client_id")
  """
  @callback join(channel_name :: String.t(), params :: map()) ::
              map() | {:error, String.t()}

  @doc """
  Optional: Return list of table names to sync for a given channel type.

  If not implemented, the sync channel will rely on the client
  specifying tables explicitly.
  """
  @callback tables_for_channel(assigns :: map()) :: [String.t()]

  @optional_callbacks [tables_for_channel: 1]
end
