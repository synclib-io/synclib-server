defmodule MMO.Schema.WorldEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "world_events" do
    field :event_type, :string
    field :title, :string
    field :description, :string
    field :document, :map
    field :last_modified_ms, :integer
    field :seqnum, :integer
    field :deleted_at, :utc_datetime
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :event_type, :title, :description, :document, :last_modified_ms, :deleted_at])
    |> validate_required([:id])
  end
end
