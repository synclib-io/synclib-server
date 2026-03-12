defmodule SyncServer.SchemaManagerBehaviour do
  @moduledoc """
  Behaviour for managing client schema versions and migrations.

  The sync server pushes SQLite DDL migrations to clients so they can
  maintain a local database that mirrors the server's schema.

  ## Example

      defmodule MyApp.SchemaManager do
        @behaviour SyncServer.SchemaManagerBehaviour

        @current_version 1

        @impl true
        def current_version, do: @current_version

        @impl true
        def check_client_version(v) when v == @current_version, do: {:ok, :up_to_date}
        def check_client_version(v) when v < @current_version do
          {:ok, migrations} = get_migrations_from(v + 1)
          {:ok, :upgrade_needed, migrations}
        end
        def check_client_version(_), do: {:error, :client_too_new}

        @impl true
        def all_migrations do
          [
            %{
              version: 1,
              description: "Initial schema",
              up: ["CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, ...)"],
              down: ["DROP TABLE IF EXISTS users"]
            }
          ]
        end
      end
  """

  @doc """
  Get the current schema version number.
  """
  @callback current_version() :: integer()

  @doc """
  Check if a client needs a schema update.

  Returns:
  - `{:ok, :up_to_date}` — client is current
  - `{:ok, :upgrade_needed, migrations}` — client needs to apply migrations
  - `{:error, :client_too_new}` — client version is ahead of server
  """
  @callback check_client_version(client_version :: integer()) ::
              {:ok, :up_to_date}
              | {:ok, :upgrade_needed, [map()]}
              | {:error, :client_too_new}

  @doc """
  Get all defined migrations.

  Each migration is a map with:
  - `:version` — integer version number
  - `:description` — human-readable description
  - `:up` — list of SQL statements to apply
  - `:down` — list of SQL statements to rollback
  """
  @callback all_migrations() :: [map()]

  @doc """
  Get migrations from a specific version to current.
  """
  @callback get_migrations_from(from_version :: integer()) :: {:ok, [map()]}

  @doc """
  Convert migrations to client-friendly format (JSON-serializable).
  """
  @callback to_client_format(migrations :: [map()]) :: [map()]

  @optional_callbacks [get_migrations_from: 1, to_client_format: 1]
end
