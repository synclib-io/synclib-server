defmodule MMO.Schema.GuildChat do
  use SyncServer.SyncSchema

  schema "guild_chat" do
    sync_fields()
    field :guild_id, :string
    field :user_id, :string
    field :message, :string
    field :document, :map
  end

  def changeset(guild_chat, attrs) do
    guild_chat
    |> cast(attrs, [:id, :guild_id, :user_id, :message, :document, :last_modified_ms, :deleted_at])
    |> validate_required([:id, :guild_id, :user_id])
  end
end
