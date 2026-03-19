defmodule Test.Schema.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "items" do
    field :document, :map
    field :room_id, :string
    field :last_modified_ms, :integer
    field :seqnum, :integer
    field :deleted_at, :utc_datetime
  end

  def changeset(item, attrs) do
    attrs = decode_document(attrs)

    item
    |> cast(attrs, [:id, :document, :room_id, :last_modified_ms, :deleted_at])
    |> validate_required([:id])
  end

  defp decode_document(%{"document" => doc} = attrs) when is_binary(doc) do
    case Jason.decode(doc) do
      {:ok, map} when is_map(map) -> Map.put(attrs, "document", map)
      _ -> Map.put(attrs, "document", %{"raw" => doc})
    end
  end
  defp decode_document(attrs), do: attrs
end
