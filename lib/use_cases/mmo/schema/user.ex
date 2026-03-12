defmodule MMO.Schema.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "users" do
    field :name, :string
    field :email, :string
    field :document, :map
    field :online, :boolean, default: false
    field :last_modified_ms, :integer
    field :seqnum, :integer
    field :deleted_at, :utc_datetime
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:id, :name, :email, :document, :online, :last_modified_ms, :deleted_at])
    |> validate_required([:id])
  end
end
