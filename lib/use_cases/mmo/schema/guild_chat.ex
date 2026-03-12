defmodule MMO.Schema.GuildChat do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "guild_chat" do
    field :guild_id, :string
    field :user_id, :string
    field :message, :string
    field :document, :map
    field :last_modified_ms, :integer
    field :seqnum, :integer
    field :deleted_at, :utc_datetime
  end

  def changeset(guild_chat, attrs) do
    guild_chat
    |> cast(attrs, [:id, :guild_id, :user_id, :message, :document, :last_modified_ms, :deleted_at])
    |> validate_required([:id, :guild_id, :user_id])
  end
end
