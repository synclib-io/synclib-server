defmodule SyncServerWeb.SyncChannel do
  @moduledoc """
  Core sync channel — handles bidirectional data sync over Phoenix channels.

  ## Protocol Messages

  ### Client → Server
  - `hello` — Client announces presence, checks schema version
  - `stream_snapshot` — Request initial table data (batched streaming)
  - `request_changes` — Pull incremental changes since a seqnum
  - `change` — Push a single change (insert/update/delete)
  - `changes_batch` — Push multiple changes at once
  - `sync` — Unified bidirectional sync (push + pull + schema in one round-trip)
  - `fetch_row` — Fetch a single row by ID
  - `schema_check` — Check if schema update needed
  - `merkle_verify` — Compare merkle roots for integrity verification
  - `merkle_block_hashes` — Compare block-level hashes to find mismatches
  - `merkle_fetch_blocks` — Fetch rows for specific blocks (server → client repair)
  - `merkle_push_blocks` — Push rows for specific blocks (client → server repair)
  - `merkle_lww_blocks` — Last-write-wins conflict resolution for blocks

  ### Server → Client
  - `snapshot_batch` — Batch of rows during snapshot streaming
  - `snapshot_complete` — Snapshot streaming finished
  - `sync_batch` — Batch of rows during unified sync
  - `sync_acks` — Acknowledgments for pushed changes
  - `sync_complete` — Unified sync finished
  - `change` — A change from another client
  - `ack` — Acknowledgment for a single change
  - `schema_update` — Server schema has been updated
  """

  use Phoenix.Channel

  alias SyncServer.Repo
  alias SyncServer.Merkle
  require Logger

  @channel_handler Application.compile_env(:sync_server, :channel_handler)
  @change_handler Application.compile_env(:sync_server, :change_handler)
  @broadcast_router Application.compile_env(:sync_server, :broadcast_router)
  @connection_handler Application.compile_env(:sync_server, :connection_handler)
  @schema_manager Application.compile_env(:sync_server, :schema_manager)
  @row_sanitizer Application.compile_env(:sync_server, :row_sanitizer, SyncServerWeb.RowSanitizer)

  # ============================================================================
  # Join
  # ============================================================================

  def join(channel_name, params, socket) do
    case @channel_handler.join(channel_name, params) do
      %{} = assigns ->
        socket = Enum.reduce(assigns, socket, fn {key, val}, acc ->
          assign(acc, key, val)
        end)

        hash_columns = Application.get_env(:sync_server, :hash_columns, [])
        socket = if hash_columns != [] do
          assign(socket, :hash_columns, hash_columns)
        else
          socket
        end

        send(self(), :after_join)

        stale_tables = case params["table_seqnums"] do
          nil -> []
          client_seqnums when is_map(client_seqnums) ->
            check_stale_tables(client_seqnums)
          _ -> []
        end

        response = %{
          status: "connected",
          server_version: @schema_manager.current_version(),
          stale_tables: stale_tables,
          hash_columns: hash_columns
        }

        {:ok, response, socket}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  defp check_stale_tables(client_seqnums) when is_map(client_seqnums) do
    client_seqnums
    |> Enum.map(fn {table, client_seqnum} ->
      case get_table_max_seqnum(table) do
        {:ok, server_seqnum} when server_seqnum > client_seqnum ->
          %{
            table: table,
            behind_by: server_seqnum - client_seqnum,
            server_seqnum: server_seqnum
          }
        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_table_max_seqnum(table) when is_binary(table) do
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, table) do
      try do
        result = Repo.query!("SELECT COALESCE(MAX(seqnum), 0) as max_seqnum FROM #{table}")
        case result.rows do
          [[max_seqnum]] -> {:ok, max_seqnum}
          _ -> {:error, :no_result}
        end
      rescue
        _ -> {:error, :query_failed}
      end
    else
      {:error, :invalid_table_name}
    end
  end

  # ============================================================================
  # After Join / Info Handlers
  # ============================================================================

  def handle_info(:after_join, socket) do
    @connection_handler.handle_connect(socket)
    Phoenix.PubSub.subscribe(SyncServer.PubSub, "schema:updated")
    {:noreply, socket}
  end

  def handle_info({:schema_updated, new_version}, socket) do
    Logger.info("[SyncChannel] Schema updated to v#{new_version}, notifying client")

    migrations = case @schema_manager.get_migrations_from(1) do
      {:ok, migs} -> @schema_manager.to_client_format(migs)
      _ -> []
    end

    push(socket, "schema_update", %{
      type: "schema_update",
      new_version: new_version,
      migrations: migrations
    })
    {:noreply, socket}
  end

  def handle_info({:snapshot_complete, stream_id, channel_id}, socket) do
    push(socket, "snapshot_complete", %{stream_id: stream_id, channel_id: channel_id})
    {:noreply, socket}
  end

  def handle_info({:sync_complete, stream_id, final_seqnums, sync_stats, elapsed_ms}, socket) do
    Logger.info("[SYNC:COMPLETE] stream=#{stream_id} client=#{sync_stats.client_id} " <>
      "push=#{sync_stats.push_success}/#{sync_stats.push_total} " <>
      "pull=#{sync_stats.pull_total} elapsed=#{elapsed_ms}ms")

    push(socket, "sync_complete", %{
      stream_id: stream_id,
      channel_id: socket.topic,
      schema_version: @schema_manager.current_version(),
      table_seqnums: final_seqnums,
      stats: %{
        push_total: sync_stats.push_total,
        push_success: sync_stats.push_success,
        push_failed: sync_stats.push_failed,
        push_by_table: sync_stats.push_by_table,
        pull_total: sync_stats.pull_total,
        pull_by_table: sync_stats.pull_by_table,
        stripped_refreshed: sync_stats.stripped_refreshed,
        elapsed_ms: elapsed_ms
      }
    })
    {:noreply, socket}
  end

  # ============================================================================
  # Hello
  # ============================================================================

  def handle_in("hello", params, socket) do
    %{
      "client_id" => client_id,
      "last_seqnum" => last_seqnum,
      "schema_version" => schema_version
    } = params

    Logger.info("Hello from #{client_id}, schema v#{schema_version}, last_seqnum: #{last_seqnum}")

    response =
      case @schema_manager.check_client_version(schema_version || 0) do
        {:ok, :up_to_date} ->
          merkle_block_size = Application.get_env(:sync_server, :merkle_block_size, 100)
          %{status: "ok", message: "Schema up to date", merkle_block_size: merkle_block_size}

        {:ok, :upgrade_needed, migrations} ->
          Logger.info("Client needs upgrade from v#{schema_version} to v#{@schema_manager.current_version()}")
          merkle_block_size = Application.get_env(:sync_server, :merkle_block_size, 100)
          %{
            status: "upgrade_needed",
            current_version: @schema_manager.current_version(),
            migrations: @schema_manager.to_client_format(migrations),
            merkle_block_size: merkle_block_size
          }

        {:error, :client_too_new} ->
          %{
            status: "error",
            error: "client_too_new",
            server_version: @schema_manager.current_version(),
            client_version: schema_version
          }
      end

    {:reply, {:ok, response}, socket}
  end

  # ============================================================================
  # Snapshot Streaming
  # ============================================================================

  def handle_in("stream_snapshot", %{"tables" => tables} = params, socket) do
    table_seqnums = params["table_seqnums"] || build_legacy_seqnum_map(tables, params["since_seqnum"])
    order_by = params["order_by"]
    order_desc = params["order_desc"] != false

    {:ok, stream_id} = start_stream(socket, tables, table_seqnums, order_by, order_desc)
    {:reply, {:ok, %{stream_id: stream_id}}, socket}
  end

  # ============================================================================
  # Schema Check
  # ============================================================================

  def handle_in("schema_check", %{"version" => client_version}, socket) do
    response =
      case @schema_manager.check_client_version(client_version) do
        {:ok, :up_to_date} ->
          %{status: "up_to_date", current_version: @schema_manager.current_version()}

        {:ok, :upgrade_needed, migrations} ->
          %{
            status: "upgrade_needed",
            current_version: @schema_manager.current_version(),
            migrations: @schema_manager.to_client_format(migrations)
          }

        {:error, :client_too_new} ->
          %{
            status: "error",
            error: "client_too_new",
            server_version: @schema_manager.current_version(),
            client_version: client_version
          }
      end

    {:reply, {:ok, response}, socket}
  end

  def handle_in("schema_migrated", %{"version" => version}, socket) do
    client_id = socket.assigns.client_id
    Logger.info("Client #{client_id} migrated to schema v#{version}")
    {:reply, {:ok, %{status: "confirmed"}}, socket}
  end

  # ============================================================================
  # Request Changes (incremental pull)
  # ============================================================================

  def handle_in("request_changes", %{"since_seqnum" => since_seqnum} = params, socket) do
    table = params["table"]
    limit = params["limit"] || 100

    tables_to_query = if table do
      [table]
    else
      get_tables_for_channel(socket.assigns)
    end

    changes = fetch_changes_from_tables(tables_to_query, since_seqnum, limit, socket.assigns)

    max_seqnum = case changes do
      [] -> since_seqnum
      _ -> changes |> Enum.map(& &1.seqnum) |> Enum.max()
    end

    response = %{
      type: "changes_batch",
      changes: changes,
      from_seqnum: since_seqnum,
      to_seqnum: max_seqnum,
      has_more: length(changes) == limit
    }

    {:reply, {:ok, response}, socket}
  end

  def handle_in("request_changes", _params, socket) do
    {:reply, {:error, %{reason: "since_seqnum is required"}}, socket}
  end

  # ============================================================================
  # Fetch Row
  # ============================================================================

  def handle_in("fetch_row", %{"table" => table, "row_id" => row_id}, socket) do
    schema = get_schema_for_table(table)

    case Repo.get(schema, row_id) do
      nil ->
        {:reply, {:error, %{reason: "not_found", table: table, row_id: row_id}}, socket}

      record ->
        claims = socket.assigns[:claims] || %{}
        client_id = socket.assigns[:client_id]
        sanitized_record = @row_sanitizer.sanitize_row(record, table, claims, client_id)
        {:reply, {:ok, %{row: serialize_row(sanitized_record)}}, socket}
    end
  rescue
    e in Postgrex.Error ->
      {:reply, {:error, %{reason: "table_not_found", table: table, message: Exception.message(e)}}, socket}
  end

  # ============================================================================
  # Single Change
  # ============================================================================

  def handle_in("change", change, socket) do
    handle_change(change, socket)
  end

  def handle_in("ack", _params, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Changes Batch
  # ============================================================================

  def handle_in("changes_batch", %{"changes" => changes}, socket) do
    results = Enum.map(changes, fn change ->
      handle_change(change, socket)
    end)

    all_ok = Enum.all?(results, fn {status, _} -> status == :ok end)

    if all_ok do
      {:reply, {:ok, %{status: "all_applied"}}, socket}
    else
      serializable_results = Enum.map(results, fn
        {:ok, data} -> %{status: "ok", data: data}
        {:error, reason} when is_binary(reason) -> %{status: "error", error: reason}
        {:error, %Ecto.Changeset{} = changeset} -> %{status: "error", error: "Validation failed", errors: translate_errors(changeset)}
        {:error, reason} -> %{status: "error", error: inspect(reason)}
      end)

      {:reply, {:error, %{status: "some_failed", results: serializable_results}}, socket}
    end
  end

  # ============================================================================
  # Unified Sync
  # ============================================================================

  def handle_in("sync", params, socket) do
    start_time = System.monotonic_time(:millisecond)
    client_id = params["client_id"] || socket.assigns[:client_id]
    schema_version = params["schema_version"] || 0
    table_seqnums = params["table_seqnums"] || %{}
    tables = params["tables"]
    force_refresh_tables = params["force_refresh_tables"] || []
    stripped_rows = params["stripped_rows"] || []
    pending_changes = params["pending_changes"] || []

    changes_by_table = Enum.group_by(pending_changes, fn c -> c["table"] end)

    Logger.info("[SYNC:START] client=#{client_id} schema_v=#{schema_version} push=#{length(pending_changes)}")

    case @schema_manager.check_client_version(schema_version) do
      {:ok, :upgrade_needed, migrations} ->
        {:reply, {:ok, %{
          status: "schema_upgrade_required",
          target_version: @schema_manager.current_version(),
          migrations: @schema_manager.to_client_format(migrations)
        }}, socket}

      {:error, :client_too_new} ->
        {:reply, {:error, %{
          status: "error",
          error: "client_schema_too_new",
          server_version: @schema_manager.current_version(),
          client_version: schema_version
        }}, socket}

      _ ->
        do_sync(socket, client_id, start_time, changes_by_table, %{
          table_seqnums: table_seqnums,
          tables: tables,
          force_refresh_tables: force_refresh_tables,
          stripped_rows: stripped_rows,
          pending_changes: pending_changes
        })
    end
  end

  # ============================================================================
  # Merkle Tree Integrity Verification
  # ============================================================================

  def handle_in("merkle_verify", %{"table_hashes" => table_hashes} = params, socket) do
    alias SyncServer.SchemaIntrospection
    block_size = params["block_size"] || 100

    Logger.info("[MERKLE:VERIFY] Checking #{map_size(table_hashes)} tables")

    mismatches =
      table_hashes
      |> Enum.map(fn {table, client_info} ->
        server_info = Merkle.compute_root(table, socket.assigns, block_size)
        client_hash = if is_map(client_info), do: client_info["root_hash"], else: client_info

        if server_info.root_hash != client_hash do
          Logger.info("[MERKLE:VERIFY] Mismatch on #{table}")

          jsonb_columns = case SchemaIntrospection.get_jsonb_columns(table) do
            {:ok, cols} -> cols
            _ -> []
          end

          scoped_row_ids = Merkle.get_scoped_row_ids(table, socket.assigns)

          %{
            table: table,
            client_hash: client_hash,
            server_root_hash: server_info.root_hash,
            server_row_count: server_info.row_count,
            server_block_count: server_info.block_count,
            jsonb_columns: jsonb_columns,
            row_ids: scoped_row_ids
          }
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    response = if length(mismatches) == 0 do
      %{status: "ok", mismatches: []}
    else
      %{status: "mismatches_found", mismatches: mismatches}
    end

    {:reply, {:ok, response}, socket}
  end

  def handle_in("merkle_block_hashes", %{"table" => table, "block_hashes" => client_hashes} = params, socket) do
    block_size = params["block_size"] || 100

    {differing_blocks, server_hashes} = Merkle.find_differing_blocks_with_hashes(table, client_hashes, socket.assigns, block_size)

    Logger.info("[MERKLE:BLOCKS] #{table}: #{length(differing_blocks)} differing out of #{length(server_hashes)} blocks")

    {:reply, {:ok, %{
      table: table,
      differing_blocks: differing_blocks,
      server_block_count: length(server_hashes)
    }}, socket}
  end

  def handle_in("merkle_fetch_blocks", %{"table" => table, "blocks" => block_indices} = params, socket) do
    block_size = params["block_size"] || 100
    claims = socket.assigns[:claims] || %{}
    client_id = socket.assigns[:client_id]
    block_index = List.first(block_indices, 0)

    rows = Merkle.get_block_rows(table, block_index, socket.assigns, block_size)
    row_ids = Merkle.get_block_row_ids(table, block_index, socket.assigns, block_size)

    sanitized_rows =
      rows
      |> Enum.map(fn row -> @row_sanitizer.sanitize_row(row, table, claims, client_id) end)
      |> Enum.reject(&is_nil/1)

    {:reply, {:ok, %{table: table, block: block_index, rows: sanitized_rows, row_ids: row_ids}}, socket}
  end

  def handle_in("merkle_push_blocks", %{"table" => table, "rows" => rows} = params, socket) do
    block_index = params["block_index"] || 0
    block_size = params["block_size"] || 100
    client_row_ids = params["client_row_ids"] || []

    {applied, rejected, errors} =
      Enum.reduce(rows, {0, 0, []}, fn row, {app, rej, errs} ->
        row_id = row["id"] || Map.get(row, :id)
        row_id_str = to_string(row_id)

        case @change_handler.apply_change(table, "update", row_id_str, row, socket.assigns) do
          {:ok, _record} ->
            broadcast_change_to_others(socket, table, "update", row_id_str, row)
            {app + 1, rej, errs}

          {:error, reason} ->
            {app, rej + 1, [%{row_id: row_id_str, error: inspect(reason)} | errs]}
        end
      end)

    server_row_ids = Merkle.get_block_row_ids(table, block_index, socket.assigns, block_size)
    client_id_set = MapSet.new(Enum.map(client_row_ids, &to_string/1))

    deleted =
      server_row_ids
      |> Enum.reject(&MapSet.member?(client_id_set, to_string(&1)))
      |> Enum.reduce(0, fn row_id, count ->
        case @change_handler.apply_change(table, "delete", to_string(row_id), %{}, socket.assigns) do
          {:ok, _} ->
            broadcast_change_to_others(socket, table, "delete", to_string(row_id), %{})
            count + 1
          _ ->
            count
        end
      end)

    {:reply, {:ok, %{
      table: table,
      block_index: block_index,
      applied: applied,
      rejected: rejected,
      deleted: deleted,
      errors: Enum.reverse(errors)
    }}, socket}
  end

  def handle_in("merkle_lww_blocks", %{"table" => table, "rows" => client_rows} = params, socket) do
    block_index = params["block_index"] || 0
    block_size = params["block_size"] || 100
    client_row_ids = params["client_row_ids"] || []
    claims = socket.assigns[:claims] || %{}
    client_id = socket.assigns[:client_id]

    server_rows = Merkle.get_block_rows(table, block_index, socket.assigns, block_size)
    server_row_map = Map.new(server_rows, fn row ->
      id = row["id"] || Map.get(row, :id)
      {to_string(id), row}
    end)

    client_row_map = Map.new(client_rows, fn row ->
      id = row["id"] || Map.get(row, :id)
      {to_string(id), row}
    end)

    all_ids = MapSet.union(
      MapSet.new(Map.keys(server_row_map)),
      MapSet.new(Enum.map(client_row_ids, &to_string/1))
    )

    {client_wins, server_wins_rows, applied, sent} =
      Enum.reduce(all_ids, {[], [], 0, 0}, fn id, {cw, sw, app, snt} ->
        client_row = client_row_map[id]
        server_row = server_row_map[id]

        cond do
          is_nil(server_row) && !is_nil(client_row) ->
            case @change_handler.apply_change(table, "insert", id, client_row, socket.assigns) do
              {:ok, _} ->
                broadcast_change_to_others(socket, table, "insert", id, client_row)
                {[id | cw], sw, app + 1, snt}
              _ ->
                {cw, sw, app, snt}
            end

          is_nil(client_row) && !is_nil(server_row) ->
            sanitized = @row_sanitizer.sanitize_row(server_row, table, claims, client_id)
            if sanitized do
              {cw, [sanitized | sw], app, snt + 1}
            else
              {cw, sw, app, snt}
            end

          true ->
            client_ts = get_lww_timestamp(client_row)
            server_ts = get_lww_timestamp(server_row)

            if client_ts > server_ts do
              case @change_handler.apply_change(table, "update", id, client_row, socket.assigns) do
                {:ok, _} ->
                  broadcast_change_to_others(socket, table, "update", id, client_row)
                  {[id | cw], sw, app + 1, snt}
                _ ->
                  {cw, sw, app, snt}
              end
            else
              sanitized = @row_sanitizer.sanitize_row(server_row, table, claims, client_id)
              if sanitized do
                {cw, [sanitized | sw], app, snt + 1}
              else
                {cw, sw, app, snt}
              end
            end
        end
      end)

    {:reply, {:ok, %{
      table: table,
      block_index: block_index,
      client_wins: Enum.reverse(client_wins),
      server_wins: Enum.reverse(server_wins_rows),
      applied_from_client: applied,
      sent_to_client: sent
    }}, socket}
  end

  # ============================================================================
  # Error handler
  # ============================================================================

  def handle_in("error", error, socket) do
    Logger.error("Client error: #{inspect(error)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Terminate
  # ============================================================================

  def terminate(reason, socket) do
    @connection_handler.handle_disconnect(reason, socket)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_lww_timestamp(nil), do: 0
  defp get_lww_timestamp(row) do
    ts = row["last_modified_ms"] || row[:last_modified_ms] ||
         row["lastModifiedMs"] || row[:lastModifiedMs] || 0
    if is_integer(ts), do: ts, else: 0
  end

  defp process_pending_changes(pending_changes, socket) do
    Enum.map(pending_changes, fn change ->
      local_seqnum = change["local_seqnum"]
      table = change["table"]
      row_id = change["row_id"]
      operation = change["operation"]
      data = change["data"] || %{}

      case @change_handler.apply_change(table, operation, row_id, data, socket.assigns) do
        {:ok, record} ->
          server_seqnum = if record, do: Map.get(record, :seqnum), else: nil
          broadcast_change_to_others(socket, table, operation, row_id, data)
          %{local_seqnum: local_seqnum, success: true, server_seqnum: server_seqnum}

        {:error, reason} ->
          error_msg = case reason do
            %Ecto.Changeset{} = changeset -> "Validation failed: #{inspect(translate_errors(changeset))}"
            msg when is_binary(msg) -> msg
            _ -> inspect(reason)
          end
          %{local_seqnum: local_seqnum, success: false, error: error_msg}
      end
    end)
  end

  defp determine_tables_to_sync(nil, assigns), do: get_tables_for_channel(assigns)
  defp determine_tables_to_sync([], assigns), do: get_tables_for_channel(assigns)
  defp determine_tables_to_sync(tables, _assigns) when is_list(tables), do: tables

  defp stream_sync_data_with_stats(socket, stream_id, tables, table_seqnums, force_refresh_tables, stripped_rows) do
    query_module = Application.get_env(:sync_server, :snapshot_queries)
    claims = socket.assigns[:claims] || %{}
    client_id = socket.assigns[:client_id]

    stripped_by_table = Enum.group_by(stripped_rows, fn row ->
      row["table"] || row[:table]
    end, fn row ->
      row["row_id"] || row[:row_id]
    end)

    Enum.reduce(tables, {%{}, %{}}, fn table, {seqnum_acc, stats_acc} ->
      force_refresh = table in force_refresh_tables
      table_seqnum = if force_refresh, do: nil, else: table_seqnums[table]

      assigns_with_params = socket.assigns |> Map.put(:since_seqnum, table_seqnum)
      query = query_module.build_query(table, assigns_with_params)

      {:ok, {row_count, max_seqnum}} = Repo.transaction(fn ->
        query
        |> Repo.stream()
        |> Stream.chunk_every(50)
        |> Enum.reduce({0, table_seqnum || 0}, fn batch, {total_rows, current_max} ->
          sanitized_rows =
            batch
            |> Enum.map(fn row -> @row_sanitizer.sanitize_row(row, table, claims, client_id) end)
            |> Enum.reject(&is_nil/1)
            |> Enum.map(&serialize_row/1)

          if length(sanitized_rows) > 0 do
            push(socket, "sync_batch", %{stream_id: stream_id, table: table, rows: sanitized_rows})
          end

          batch_max = batch
            |> Enum.map(fn row -> Map.get(row, :seqnum) || 0 end)
            |> Enum.max(fn -> current_max end)

          {total_rows + length(sanitized_rows), max(current_max, batch_max)}
        end)
      end)

      table_stripped_ids = stripped_by_table[table] || []
      stripped_count = if length(table_stripped_ids) > 0 do
        fetch_and_push_stripped_rows(socket, stream_id, table, table_stripped_ids, claims, client_id)
      else
        0
      end

      {Map.put(seqnum_acc, table, max_seqnum), Map.put(stats_acc, table, %{rows: row_count, stripped: stripped_count})}
    end)
  end

  defp fetch_and_push_stripped_rows(socket, stream_id, table, row_ids, claims, client_id) do
    schema = get_schema_for_table(table)

    rows = Enum.flat_map(row_ids, fn row_id ->
      case Repo.get(schema, row_id) do
        nil -> []
        record ->
          sanitized = @row_sanitizer.sanitize_row(record, table, claims, client_id)
          if sanitized, do: [serialize_row(sanitized)], else: []
      end
    end)

    if length(rows) > 0 do
      push(socket, "sync_batch", %{
        stream_id: stream_id,
        table: table,
        rows: rows,
        is_stripped_refresh: true
      })
    end

    length(rows)
  end

  defp handle_change(change, socket) do
    %{
      "table" => table,
      "operation" => operation,
      "row_id" => row_id,
      "seqnum" => seqnum
    } = change

    data = Map.get(change, "data", %{})

    case @change_handler.apply_change(table, operation, row_id, data, socket.assigns) do
      {:ok, record} ->
        server_seqnum = if record, do: Map.get(record, :seqnum), else: nil
        push(socket, "ack", %{seqnum: seqnum, success: true, server_seqnum: server_seqnum})
        broadcast_change_to_others(socket, table, operation, row_id, data)
        {:ok, %{seqnum: seqnum, server_seqnum: server_seqnum}}

      {:error, reason} ->
        error_msg = case reason do
          %Ecto.Changeset{} = changeset -> "Validation failed: #{inspect(translate_errors(changeset))}"
          msg when is_binary(msg) -> msg
          _ -> inspect(reason)
        end
        push(socket, "ack", %{seqnum: seqnum, success: false, error: error_msg})
        {:error, reason}
    end
  end

  defp start_stream(socket, tables, table_seqnums, order_by, order_desc) do
    stream_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    query_module = Application.get_env(:sync_server, :snapshot_queries)
    channel_pid = self()

    Task.start(fn ->
      Enum.each(tables, fn table ->
        table_seqnum = if table_seqnums, do: table_seqnums[table], else: nil
        assigns_with_params = socket.assigns
          |> Map.put(:since_seqnum, table_seqnum)
          |> Map.put(:order_by, order_by)
          |> Map.put(:order_desc, order_desc)
        query = query_module.build_query(table, assigns_with_params)

        {:ok, _} = Repo.transaction(fn ->
          query
          |> Repo.stream()
          |> Stream.chunk_every(50)
          |> Enum.each(fn batch ->
            claims = socket.assigns[:claims] || %{}
            client_id = socket.assigns[:client_id]
            sanitized_rows =
              batch
              |> Enum.map(fn row -> @row_sanitizer.sanitize_row(row, table, claims, client_id) end)
              |> Enum.reject(&is_nil/1)
              |> Enum.map(&serialize_row/1)

            push(socket, "snapshot_batch", %{
              stream_id: stream_id,
              table: table,
              rows: sanitized_rows
            })
          end)
        end)
      end)

      send(channel_pid, {:snapshot_complete, stream_id, socket.topic})
    end)

    {:ok, stream_id}
  end

  defp serialize_row(nil), do: nil
  defp serialize_row(%{} = map) when not is_struct(map), do: map
  defp serialize_row(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  defp get_schema_for_table(table) do
    @change_handler.get_schema_for_table(table)
  end

  defp broadcast_change_to_others(socket, table, operation, row_id, data) do
    @broadcast_router.broadcast_change(socket, table, operation, row_id, data)
  end

  defp get_tables_for_channel(assigns) do
    if function_exported?(@channel_handler, :tables_for_channel, 1) do
      @channel_handler.tables_for_channel(assigns)
    else
      []
    end
  end

  defp fetch_changes_from_tables(tables, since_seqnum, limit, assigns) do
    query_module = Application.get_env(:sync_server, :snapshot_queries)

    tables
    |> Enum.flat_map(fn table ->
      try do
        assigns_with_seqnum = Map.put(assigns, :since_seqnum, since_seqnum)
        query = query_module.build_query(table, assigns_with_seqnum)
        claims = assigns[:claims] || %{}
        client_id = assigns[:client_id]

        query
        |> Repo.all()
        |> Enum.map(fn row ->
          sanitized_row = @row_sanitizer.sanitize_row(row, table, claims, client_id)
          %{
            table: table,
            row: serialize_row(sanitized_row),
            seqnum: sanitized_row.seqnum
          }
        end)
      rescue
        e ->
          Logger.error("Error querying table #{table}: #{inspect(e)}")
          []
      end
    end)
    |> Enum.sort_by(& &1.seqnum)
    |> Enum.take(limit)
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  defp build_legacy_seqnum_map(_tables, nil), do: nil
  defp build_legacy_seqnum_map(tables, since_seqnum) do
    Enum.into(tables, %{}, fn table -> {table, since_seqnum} end)
  end

  defp do_sync(socket, client_id, start_time, changes_by_table, params) do
    %{
      table_seqnums: table_seqnums,
      tables: tables,
      force_refresh_tables: force_refresh_tables,
      stripped_rows: stripped_rows,
      pending_changes: pending_changes
    } = params

    channel_pid = self()
    stream_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Task.start(fn ->
      sync_stats = %{
        stream_id: stream_id,
        client_id: client_id,
        start_time: start_time,
        push_total: length(pending_changes),
        push_success: 0,
        push_failed: 0,
        push_by_table: %{},
        pull_total: 0,
        pull_by_table: %{},
        stripped_refreshed: 0
      }

      # 1. Process pending changes
      acks = process_pending_changes(pending_changes, socket)

      success_count = Enum.count(acks, fn a -> a.success end)
      failed_count = length(acks) - success_count
      push_by_table = changes_by_table
        |> Enum.map(fn {table, changes} ->
          table_acks = Enum.filter(acks, fn a ->
            Enum.any?(changes, fn c -> c["local_seqnum"] == a.local_seqnum end)
          end)
          success = Enum.count(table_acks, fn a -> a.success end)
          {table, %{total: length(changes), success: success, failed: length(changes) - success}}
        end)
        |> Enum.into(%{})

      sync_stats = %{sync_stats |
        push_success: success_count,
        push_failed: failed_count,
        push_by_table: push_by_table
      }

      if length(acks) > 0 do
        push(socket, "sync_acks", %{stream_id: stream_id, acks: acks})
      end

      # 2. Determine tables
      tables_to_sync = determine_tables_to_sync(tables, socket.assigns)

      # 3. Stream data
      {final_seqnums, pull_stats} = stream_sync_data_with_stats(
        socket, stream_id, tables_to_sync, table_seqnums,
        force_refresh_tables, stripped_rows
      )

      sync_stats = %{sync_stats |
        pull_total: Enum.sum(Map.values(pull_stats) |> Enum.map(fn s -> s.rows end)),
        pull_by_table: pull_stats,
        stripped_refreshed: Enum.sum(Map.values(pull_stats) |> Enum.map(fn s -> s.stripped end))
      }

      elapsed = System.monotonic_time(:millisecond) - start_time
      send(channel_pid, {:sync_complete, stream_id, final_seqnums, sync_stats, elapsed})
    end)

    {:reply, {:ok, %{stream_id: stream_id}}, socket}
  end
end
