defmodule SyncServer.SyncSchema do
  @moduledoc """
  Shared schema macro for synced tables.

  Provides common primary key config and sync fields (seqnum, row_hash,
  deleted_at, last_modified_ms) so every schema stays consistent.

  Usage:

      defmodule MyApp.Schema.Item do
        use SyncServer.SyncSchema

        schema "items" do
          sync_fields()
          field :name, :string
          # ...
        end
      end

  Note: `row_hash` is computed by a Postgres trigger and must NOT be included
  in changeset `cast` fields.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import SyncServer.SyncSchema, only: [sync_fields: 0]
      @primary_key {:id, :string, autogenerate: false}
    end
  end

  defmacro sync_fields do
    quote do
      field :seqnum, :integer, read_after_writes: true
      field :row_hash, :string, read_after_writes: true
      field :deleted_at, :utc_datetime
      field :last_modified_ms, :integer
    end
  end
end
