defmodule SyncServer.Hash do
  @moduledoc """
  Cross-platform hashing using synclib_hash WASM.

  This module provides consistent merkle tree hashing that matches
  all client implementations (C, TypeScript, Dart) by using the same
  underlying C code compiled to WebAssembly.

  ## Hash Format

  - Row hash: SHA256(row_id + "|" + sorted_json(row_data)) -> lowercase hex
  - Block hash: SHA256(concat of row hash hex strings) -> lowercase hex
  - Merkle root: Binary tree of block hashes, odd node passed up as-is
  """

  use GenServer
  require Logger

  @wasm_file "synclib_hash.wasm"

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Build sorted JSON from a map.

  Keys are sorted alphabetically. Specified keys are skipped.
  This matches the C implementation exactly.
  """
  def build_sorted_json(row_map, skip_keys \\ []) when is_map(row_map) do
    GenServer.call(__MODULE__, {:build_sorted_json, row_map, skip_keys})
  end

  @doc """
  Compute row hash.

  Format: SHA256(row_id + "|" + sorted_json) -> lowercase hex (64 chars)
  """
  def row_hash(row_id, sorted_json) when is_binary(row_id) and is_binary(sorted_json) do
    GenServer.call(__MODULE__, {:row_hash, row_id, sorted_json})
  end

  @doc """
  Compute row hash from a map.

  Convenience function that builds sorted JSON internally.
  """
  def row_hash_from_map(row_id, row_map, skip_keys \\ []) do
    json = build_sorted_json(row_map, skip_keys)
    row_hash(row_id, json)
  end

  @doc """
  Compute block hash from a list of row hashes.

  Format: SHA256(row_hash_1 + row_hash_2 + ... + row_hash_n) -> lowercase hex
  """
  def block_hash(row_hashes) when is_list(row_hashes) do
    GenServer.call(__MODULE__, {:block_hash, row_hashes})
  end

  @doc """
  Build merkle root from a list of block hashes.

  Uses binary tree structure. Odd nodes are passed up as-is.
  """
  def merkle_root(block_hashes) when is_list(block_hashes) do
    GenServer.call(__MODULE__, {:merkle_root, block_hashes})
  end

  @doc """
  Compute SHA256 hash and return as lowercase hex.
  """
  def sha256_hex(data) when is_binary(data) do
    GenServer.call(__MODULE__, {:sha256_hex, data})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    wasm_path = Application.app_dir(:sync_server, ["priv", @wasm_file])

    case File.read(wasm_path) do
      {:ok, bytes} ->
        case Wasmex.start_link(%{bytes: bytes}) do
          {:ok, wasm_pid} ->
            Logger.info("[SyncServer.Hash] WASM module loaded successfully")
            {:ok, %{wasm_pid: wasm_pid}}

          {:error, reason} ->
            Logger.error("[SyncServer.Hash] Failed to start WASM instance: #{inspect(reason)}")
            {:stop, {:wasm_start_error, reason}}
        end

      {:error, reason} ->
        Logger.error("[SyncServer.Hash] Failed to read WASM file at #{wasm_path}: #{inspect(reason)}")
        {:stop, {:wasm_file_error, reason}}
    end
  end

  @impl true
  def handle_call({:build_sorted_json, row_map, skip_keys}, _from, state) do
    result = build_sorted_json_wasm(state, row_map, skip_keys)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:row_hash, row_id, sorted_json}, _from, state) do
    hash_input = "#{row_id}|#{sorted_json}"
    result = compute_sha256_hex(state, hash_input)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:block_hash, row_hashes}, _from, state) do
    result = compute_block_hash_wasm(state, row_hashes)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:merkle_root, []}, _from, state) do
    {:reply, "", state}
  end

  @impl true
  def handle_call({:merkle_root, [single]}, _from, state) do
    {:reply, single, state}
  end

  @impl true
  def handle_call({:merkle_root, block_hashes}, _from, state) do
    result = build_merkle_root_recursive(state, block_hashes)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:sha256_hex, data}, _from, state) do
    result = compute_sha256_hex(state, data)
    {:reply, result, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp build_sorted_json_wasm(%{wasm_pid: wasm_pid}, row_map, skip_keys) do
    input_json = Jason.encode!(row_map)
    input_bytes = input_json <> <<0>>
    input_len = byte_size(input_bytes)

    {:ok, store} = Wasmex.store(wasm_pid)
    {:ok, memory} = Wasmex.memory(wasm_pid)

    {:ok, [input_ptr]} = Wasmex.call_function(wasm_pid, "malloc", [input_len])
    :ok = Wasmex.Memory.write_binary(store, memory, input_ptr, input_bytes)

    skip_keys_list = Enum.map(skip_keys, &to_string/1)
    skip_count = length(skip_keys_list)

    skip_keys_ptr = if skip_count > 0 do
      {:ok, [ptr]} = Wasmex.call_function(wasm_pid, "malloc", [skip_count * 4])

      skip_key_ptrs = Enum.map(skip_keys_list, fn key ->
        key_bytes = key <> <<0>>
        {:ok, [key_ptr]} = Wasmex.call_function(wasm_pid, "malloc", [byte_size(key_bytes)])
        :ok = Wasmex.Memory.write_binary(store, memory, key_ptr, key_bytes)
        key_ptr
      end)

      skip_key_ptrs
      |> Enum.with_index()
      |> Enum.each(fn {key_ptr, idx} ->
        :ok = Wasmex.Memory.write_binary(store, memory, ptr + idx * 4, <<key_ptr::little-32>>)
      end)

      {ptr, skip_key_ptrs}
    else
      {0, []}
    end

    {skip_arr_ptr, skip_key_ptrs} = skip_keys_ptr

    {:ok, [result_ptr]} = Wasmex.call_function(
      wasm_pid,
      "synclib_build_sorted_json_from_json",
      [input_ptr, skip_arr_ptr, skip_count]
    )

    result = if result_ptr != 0 do
      read_null_terminated_string(store, memory, result_ptr)
    else
      "{}"
    end

    if result_ptr != 0, do: Wasmex.call_function(wasm_pid, "synclib_free", [result_ptr])
    Wasmex.call_function(wasm_pid, "free", [input_ptr])
    if skip_arr_ptr != 0 do
      Enum.each(skip_key_ptrs, fn ptr ->
        Wasmex.call_function(wasm_pid, "free", [ptr])
      end)
      Wasmex.call_function(wasm_pid, "free", [skip_arr_ptr])
    end

    result
  end

  defp read_null_terminated_string(store, memory, ptr) do
    read_null_terminated_string(store, memory, ptr, [], 0)
  end

  defp read_null_terminated_string(store, memory, ptr, acc, offset) do
    chunk_size = 256
    chunk = Wasmex.Memory.read_binary(store, memory, ptr + offset, chunk_size)

    case :binary.match(chunk, <<0>>) do
      {pos, 1} ->
        final_chunk = binary_part(chunk, 0, pos)
        IO.iodata_to_binary([acc, final_chunk])

      :nomatch ->
        read_null_terminated_string(store, memory, ptr, [acc, chunk], offset + chunk_size)
    end
  end

  defp compute_sha256_hex(%{wasm_pid: wasm_pid}, data) do
    data_bytes = data <> <<0>>
    data_len = byte_size(data_bytes)

    {:ok, [data_ptr]} = Wasmex.call_function(wasm_pid, "malloc", [data_len])

    {:ok, store} = Wasmex.store(wasm_pid)
    {:ok, memory} = Wasmex.memory(wasm_pid)

    :ok = Wasmex.Memory.write_binary(store, memory, data_ptr, data_bytes)

    {:ok, [result_ptr]} = Wasmex.call_function(wasm_pid, "synclib_sha256_hex", [data_ptr, byte_size(data)])

    result = Wasmex.Memory.read_string(store, memory, result_ptr, 64)

    Wasmex.call_function(wasm_pid, "synclib_free", [result_ptr])
    Wasmex.call_function(wasm_pid, "free", [data_ptr])

    result
  end

  defp compute_block_hash_wasm(%{wasm_pid: wasm_pid}, row_hashes) do
    count = length(row_hashes)

    if count == 0 do
      compute_sha256_hex(%{wasm_pid: wasm_pid}, "")
    else
      {:ok, store} = Wasmex.store(wasm_pid)
      {:ok, memory} = Wasmex.memory(wasm_pid)

      {:ok, [array_ptr]} = Wasmex.call_function(wasm_pid, "malloc", [count * 4])

      hash_ptrs = Enum.map(row_hashes, fn hash ->
        hash_bytes = hash <> <<0>>
        {:ok, [ptr]} = Wasmex.call_function(wasm_pid, "malloc", [byte_size(hash_bytes)])
        :ok = Wasmex.Memory.write_binary(store, memory, ptr, hash_bytes)
        ptr
      end)

      hash_ptrs
      |> Enum.with_index()
      |> Enum.each(fn {ptr, idx} ->
        ptr_bytes = <<ptr::little-32>>
        :ok = Wasmex.Memory.write_binary(store, memory, array_ptr + idx * 4, ptr_bytes)
      end)

      {:ok, [result_ptr]} = Wasmex.call_function(wasm_pid, "synclib_block_hash", [array_ptr, count])

      result = Wasmex.Memory.read_string(store, memory, result_ptr, 64)

      Wasmex.call_function(wasm_pid, "synclib_free", [result_ptr])
      Enum.each(hash_ptrs, fn ptr ->
        Wasmex.call_function(wasm_pid, "free", [ptr])
      end)
      Wasmex.call_function(wasm_pid, "free", [array_ptr])

      result
    end
  end

  defp build_merkle_root_recursive(_state, []), do: ""
  defp build_merkle_root_recursive(_state, [single]), do: single
  defp build_merkle_root_recursive(state, hashes) do
    next_level =
      hashes
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [a, b] ->
          combined = a <> b
          compute_sha256_hex(state, combined)
        [a] ->
          a
      end)

    build_merkle_root_recursive(state, next_level)
  end
end
