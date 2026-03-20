defmodule MMO.Schema.WorldEvent do
  use SyncServer.SyncSchema

  schema "world_events" do
    sync_fields()
    field :event_type, :string
    field :title, :string
    field :description, :string
    field :document, :map
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :event_type, :title, :description, :document, :last_modified_ms, :deleted_at])
    |> validate_required([:id])
  end
end
