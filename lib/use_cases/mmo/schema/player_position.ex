defmodule MMO.Schema.PlayerPosition do
  use SyncServer.SyncSchema

  schema "player_positions" do
    sync_fields()
    field :user_id, :string
    field :zone_id, :string
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0
    field :z, :float, default: 0.0
    field :document, :map
  end

  def changeset(position, attrs) do
    position
    |> cast(attrs, [:id, :user_id, :zone_id, :x, :y, :z, :document, :last_modified_ms, :deleted_at])
    |> validate_required([:id, :user_id, :zone_id])
  end
end
