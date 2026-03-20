defmodule MMO.Schema.Task do
  use SyncServer.SyncSchema

  schema "tasks" do
    sync_fields()
    field :user_id, :string
    field :title, :string
    field :description, :string
    field :status, :string, default: "pending"
    field :document, :map
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:id, :user_id, :title, :description, :status, :document, :last_modified_ms, :deleted_at])
    |> validate_required([:id, :user_id])
  end
end
