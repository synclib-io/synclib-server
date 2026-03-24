defmodule SyncServer.Merkle do
  @moduledoc """
  Merkle tree computation for PostgreSQL tables.

  Computes row hashes, block hashes, and Merkle roots for data integrity verification.
  Uses the same query logic as SnapshotQueries to ensure hashes are computed over
  the same filtered dataset the client has.

  Hash format: SHA256(row_id || '|' || sorted_json(row_data))

  When the pg_synclib_hash extension is installed, uses precomputed `row_hash`
  columns (set by Postgres trigger) for fast merkle verification. Falls back to
  WASM-based computation when row_hash is not available.
  """

  import Ecto.Query
  alias SyncServer.Repo
  alias SyncServer.Hash
  require Logger

  @default_block_size 100

  # Columns to skip in hash computation
  @skip_columns [:__meta__]

  @doc """
  Compute Merkle root hash for a table, scoped to channel assigns.

  Uses the configured snapshot_queries module to get the same filtered dataset
  that the client would receive during sync.

  Returns:
    %{
      root_hash: hex string,
      block_count: integer,
      row_count: integer
    }
  """
  def compute_root(table_name, assigns, block_size \\ @default_block_size) do
    query_module = Application.get_env(:sync_server, :snapshot_queries)
    hash_columns = Map.get(assigns, :hash_columns)

    base_assigns = Map.delete(assigns, :since_seqnum)
    base_query = query_module.build_query(table_name, base_assigns)

    # Use precomputed row_hash column (set by pg_synclib_hash trigger).
    # In server-authoritative mode this is the only correct path — the slow
    # path re-computes hashes from row data which is wasteful and can diverge.
    case query_precomputed_hashes(base_query, table_name) do
      {:ok, row_hashes} ->
        compute_root_from_precomputed(row_hashes, block_size)

      :fallback ->
        Logger.warning("[MERKLE] #{table_name}: row_hash fast path failed, falling back to slow computation. " <>
          "Ensure the row_hash column exists and the pg_synclib_hash trigger is installed.")
        compute_root_from_rows(base_query, block_size, hash_columns)
    end
  end

  defp compute_root_from_precomputed(row_hashes, block_size) do
    row_count = length(row_hashes)

    if row_count == 0 do
      %{
        root_hash: Hash.sha256_hex(""),
        block_count: 0,
        row_count: 0
      }
    else
      block_hashes =
        row_hashes
        |> Enum.chunk_every(block_size)
        |> Enum.map(fn chunk -> Hash.block_hash(chunk) end)

      root_hash = Hash.merkle_root(block_hashes)

      %{
        root_hash: root_hash,
        block_count: length(block_hashes),
        row_count: row_count
      }
    end
  end

  defp compute_root_from_rows(base_query, block_size, hash_columns) do
    ordered_query = from(q in base_query, where: is_nil(q.deleted_at), order_by: q.id)
    rows = Repo.all(ordered_query)
    row_count = length(rows)

    if row_count == 0 do
      %{
        root_hash: Hash.sha256_hex(""),
        block_count: 0,
        row_count: 0
      }
    else
      block_hashes = compute_block_hashes_from_rows(rows, block_size, hash_columns)
      root_hash = Hash.merkle_root(block_hashes)

      %{
        root_hash: root_hash,
        block_count: length(block_hashes),
        row_count: row_count
      }
    end
  end

  defp query_precomputed_hashes(base_query, table_name) do
    check_sql = """
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = 'row_hash'
    )
    """

    case Repo.query(check_sql, [table_name]) do
      {:ok, %{rows: [[true]]}} ->
        fetch_precomputed_hashes(base_query)

      _ ->
        :fallback
    end
  rescue
    e ->
      Logger.error("[MERKLE] query_precomputed_hashes failed: #{inspect(e)}")
      :fallback
  end

  defp fetch_precomputed_hashes(base_query) do
    # Use qualified reference (q.row_hash) to avoid ambiguity when the
    # base_query includes JOINs (e.g. subcollection tables joining parents).
    query = from(q in base_query,
      where: is_nil(q.deleted_at),
      order_by: q.id,
      select: fragment("COALESCE(?, '')", q.row_hash)
    )

    hashes = Repo.all(query)
    {:ok, hashes}
  rescue
    e ->
      Logger.error("[MERKLE] fetch_precomputed_hashes failed: #{inspect(e)}")
      :fallback
  end

  @doc """
  Compute all block hashes from a list of rows.

  Rows should already be ordered by id.
  """
  def compute_block_hashes_from_rows(rows, block_size \\ @default_block_size, hash_columns \\ nil) do
    rows
    |> Enum.chunk_every(block_size)
    |> Enum.map(fn chunk -> compute_block_hash_from_rows(chunk, hash_columns: hash_columns) end)
  end

  @doc """
  Compute hash for a block of rows.

  Block hash = SHA256(row_hash_1 || row_hash_2 || ... || row_hash_n)
  """
  def compute_block_hash_from_rows(rows, opts \\ []) do
    debug = Keyword.get(opts, :debug, false)
    hash_columns = Keyword.get(opts, :hash_columns)

    row_hashes =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, idx} ->
        row_opts = if hash_columns, do: [hash_columns: hash_columns], else: []
        row_opts = if debug && idx == 0, do: [{:debug, true} | row_opts], else: row_opts
        compute_row_hash(row, row_opts)
      end)

    Hash.block_hash(row_hashes)
  end

  @doc """
  Debug a specific row's hash computation.
  Call this from iex to compare with client output.
  """
  def debug_row_hash(table_name, row_id, assigns) do
    query_module = Application.get_env(:sync_server, :snapshot_queries)
    base_assigns = Map.delete(assigns, :since_seqnum)
    base_query = query_module.build_query(table_name, base_assigns)

    query = from(q in base_query, where: q.id == ^row_id)
    case Repo.one(query) do
      nil ->
        Logger.error("[MERKLE:DEBUG] Row not found: #{table_name}.#{row_id}")
        nil
      row ->
        schema_module = row.__struct__
        row_map = struct_to_db_column_map(row, schema_module)
        sorted_json = Hash.build_sorted_json(row_map, Enum.map(@skip_columns, &to_string/1))
        row_hash = Hash.row_hash(row_id, sorted_json)

        Logger.info("[MERKLE:DEBUG] Table: #{table_name}, Row ID: #{row_id}")
        Logger.info("[MERKLE:DEBUG] Sorted JSON: #{sorted_json}")
        Logger.info("[MERKLE:DEBUG] Row hash: #{row_hash}")

        %{sorted_json: sorted_json, row_hash: row_hash}
    end
  end

  @doc """
  Compute hash for a single row (Ecto struct or map).

  Hash format: SHA256(row_id || '|' || sorted_json(row_data))

  Uses database column names (not Ecto field names) for cross-platform
  consistency with clients that read directly from SQLite.
  """
  def compute_row_hash(row, opts \\ []) do
    hash_columns = Keyword.get(opts, :hash_columns)

    row_map = case row do
      %{__struct__: schema_module} = struct ->
        struct_to_db_column_map(struct, schema_module, hash_columns)
      map when hash_columns != nil ->
        keep_keys = ["id" | hash_columns]
        Map.take(map, keep_keys)
      map ->
        Map.drop(map, [:__meta__])
    end

    id = get_row_id(row_map)

    skip_keys = if hash_columns, do: [], else: Enum.map(@skip_columns, &to_string/1)
    sorted_json = Hash.build_sorted_json(row_map, skip_keys)

    if Keyword.get(opts, :debug, false) do
      Logger.info("[MERKLE:DEBUG] Row ID: #{id}")
      Logger.info("[MERKLE:DEBUG] Sorted JSON (first 500 chars): #{String.slice(sorted_json, 0..500)}")
    end

    Hash.row_hash(id, sorted_json)
  end

  @doc """
  Get rows for a specific block, scoped to channel assigns.
  """
  def get_block_rows(table_name, block_index, assigns, block_size \\ @default_block_size) do
    query_module = Application.get_env(:sync_server, :snapshot_queries)
    base_assigns = Map.delete(assigns, :since_seqnum)
    base_query = query_module.build_query(table_name, base_assigns)

    offset = block_index * block_size

    query = from(q in base_query,
      where: is_nil(q.deleted_at),
      order_by: q.id,
      limit: ^block_size,
      offset: ^offset
    )

    Repo.all(query)
    |> Enum.map(&row_to_map/1)
  end

  @doc """
  Get row IDs for a specific block.
  """
  def get_block_row_ids(table_name, block_index, assigns, block_size \\ @default_block_size) do
    query_module = Application.get_env(:sync_server, :snapshot_queries)
    base_assigns = Map.delete(assigns, :since_seqnum)
    base_query = query_module.build_query(table_name, base_assigns)

    offset = block_index * block_size

    query = from(q in base_query,
      where: is_nil(q.deleted_at),
      order_by: q.id,
      limit: ^block_size,
      offset: ^offset,
      select: q.id
    )

    Repo.all(query)
  end

  @doc """
  Get all scoped row IDs for a table (ordered by id, excluding soft-deleted).
  Used to tell clients which rows are in scope for a given channel.
  """
  def get_scoped_row_ids(table_name, assigns) do
    query_module = Application.get_env(:sync_server, :snapshot_queries)
    base_assigns = Map.delete(assigns, :since_seqnum)
    base_query = query_module.build_query(table_name, base_assigns)

    query = from(q in base_query,
      where: is_nil(q.deleted_at),
      order_by: q.id,
      select: q.id
    )

    Repo.all(query)
  end

  @doc """
  Compute all block hashes for a table.

  Returns a list of hex-encoded block hashes in order.
  Uses precomputed row_hash column when available (fast path).
  """
  def compute_block_hashes(table_name, assigns, block_size \\ @default_block_size) do
    query_module = Application.get_env(:sync_server, :snapshot_queries)
    hash_columns = Map.get(assigns, :hash_columns)
    base_assigns = Map.delete(assigns, :since_seqnum)
    base_query = query_module.build_query(table_name, base_assigns)

    if hash_columns do
      ordered_query = from(q in base_query, where: is_nil(q.deleted_at), order_by: q.id)
      rows = Repo.all(ordered_query)
      compute_block_hashes_from_rows(rows, block_size, hash_columns)
    else
      case query_precomputed_hashes(base_query, table_name) do
        {:ok, row_hashes} ->
          row_hashes
          |> Enum.chunk_every(block_size)
          |> Enum.map(fn chunk -> Hash.block_hash(chunk) end)

        :fallback ->
          ordered_query = from(q in base_query, where: is_nil(q.deleted_at), order_by: q.id)
          rows = Repo.all(ordered_query)
          compute_block_hashes_from_rows(rows, block_size)
      end
    end
  end

  @doc """
  Find which blocks differ between client and server.

  Returns a list of block indices that have different hashes.
  """
  def find_differing_blocks(table_name, client_block_hashes, assigns, block_size) do
    {differing, _server_hashes} = find_differing_blocks_with_hashes(table_name, client_block_hashes, assigns, block_size)
    differing
  end

  @doc """
  Find differing blocks and return server hashes too.

  Returns {differing_block_indices, server_hashes} to avoid computing hashes twice.
  """
  def find_differing_blocks_with_hashes(table_name, client_block_hashes, assigns, block_size) do
    server_hashes = compute_block_hashes(table_name, assigns, block_size)

    max_blocks = max(length(client_block_hashes), length(server_hashes))

    differing = if max_blocks == 0 do
      []
    else
      0..(max_blocks - 1)
      |> Enum.filter(fn index ->
        client_hash = Enum.at(client_block_hashes, index)
        server_hash = Enum.at(server_hashes, index)
        client_hash != server_hash
      end)
    end

    {differing, server_hashes}
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp struct_to_db_column_map(struct, schema_module, hash_columns \\ nil) do
    fields = schema_module.__schema__(:fields)

    filtered_fields = if hash_columns do
      fields
      |> Enum.filter(fn field ->
        source = to_string(schema_module.__schema__(:field_source, field))
        source == "id" || source in hash_columns
      end)
    else
      fields
      |> Enum.reject(fn field ->
        field in @skip_columns
      end)
    end

    filtered_fields
    |> Enum.map(fn field ->
      source = schema_module.__schema__(:field_source, field)
      value = Map.get(struct, field)
      normalized_value = normalize_value_for_sqlite(value)
      {source, normalized_value}
    end)
    |> Enum.into(%{})
  end

  defp is_array_field?(schema_module, field) do
    case schema_module.__schema__(:type, field) do
      {:array, _} -> true
      _ -> false
    end
  end

  defp normalize_value_for_sqlite(true), do: 1
  defp normalize_value_for_sqlite(false), do: 0
  defp normalize_value_for_sqlite(list) when is_list(list), do: Jason.encode!(list)
  defp normalize_value_for_sqlite(value), do: value

  defp get_row_id(row_map) do
    cond do
      is_map_key(row_map, :id) -> to_string(Map.get(row_map, :id))
      is_map_key(row_map, "id") -> to_string(Map.get(row_map, "id"))
      true -> ""
    end
  end

  defp row_to_map(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> encode_map_values()
  end
  defp row_to_map(map), do: encode_map_values(map)

  defp encode_map_values(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), encode_value(v)} end)
    |> Enum.into(%{})
  end

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp encode_value(%Date{} = d), do: Date.to_iso8601(d)
  defp encode_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp encode_value(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> encode_map_values()
  end
  defp encode_value(map) when is_map(map), do: encode_map_values(map)
  defp encode_value(list) when is_list(list), do: Enum.map(list, &encode_value/1)
  defp encode_value(value), do: value
end
