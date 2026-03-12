defmodule MMO.Schema.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "tasks" do
    field :user_id, :string
    field :title, :string
    field :description, :string
    field :status, :string, default: "pending"
    field :document, :map
    field :last_modified_ms, :integer
    field :seqnum, :integer
    field :deleted_at, :utc_datetime
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:id, :user_id, :title, :description, :status, :document, :last_modified_ms, :deleted_at])
    |> validate_required([:id, :user_id])
  end
end
