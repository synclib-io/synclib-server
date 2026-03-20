defmodule MMO.Schema.User do
  use SyncServer.SyncSchema

  schema "users" do
    sync_fields()
    field :name, :string
    field :email, :string
    field :document, :map
    field :online, :boolean, default: false
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:id, :name, :email, :document, :online, :last_modified_ms, :deleted_at])
    |> validate_required([:id])
  end
end
