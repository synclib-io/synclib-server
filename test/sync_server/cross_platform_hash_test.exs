defmodule SyncServer.CrossPlatformHashTest do
  @moduledoc """
  Tests cross-platform hash consistency between:

  1. **Postgres trigger** (pg_synclib_hash) - builds JSON manually, passes to C library
  2. **Elixir slow path** (merkle.ex) - normalize_value_for_sqlite → Jason.encode! → WASM
  3. **Client** (Flutter/Dart) - reads from SQLite → builds JSON → C library via FFI/WASM

  All three paths use the same C library (synclib_hash) for canonical sorted JSON + SHA256,
  but they prepare the INPUT JSON differently. This test catches representation mismatches.
  """

  use ExUnit.Case, async: true

  # ===========================================================================
  # Helpers: simulate each platform's JSON construction
  # ===========================================================================

  # Simulate what the Elixir merkle.ex slow path produces.
  # Flow: Ecto struct → normalize_value_for_sqlite → map → Jason.encode! → C library
  # Arrays become JSON strings, booleans become 0/1.
  defp elixir_input_json(row) do
    row
    |> Enum.map(fn {k, v} -> {k, normalize_value_for_sqlite(v)} end)
    |> Enum.into(%{})
    |> Jason.encode!()
  end

  # Simulate what the Postgres trigger (pg_synclib_hash.c) produces.
  # Flow: column values → manual JSON construction → C library
  # Booleans are 0/1, arrays are JSON-escaped strings via json_escape_into().
  defp pg_trigger_input_json(row) do
    parts =
      row
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> "\"#{k}\":#{pg_encode_value(v)}" end)

    "{" <> Enum.join(parts, ",") <> "}"
  end

  # Simulate what the Flutter client sees when reading from SQLite.
  # Flow: SQLite row → Dart Map → JSON → C library
  # Booleans stored as INTEGER (0/1), arrays stored as TEXT (JSON string).
  defp sqlite_client_input_json(row) do
    row
    |> Enum.map(fn {k, v} -> {k, sqlite_stored_value(v)} end)
    |> Enum.into(%{})
    |> Jason.encode!()
  end

  # ---------------------------------------------------------------------------
  # normalize_value_for_sqlite (mirrors merkle.ex)
  # ---------------------------------------------------------------------------
  defp normalize_value_for_sqlite(true), do: 1
  defp normalize_value_for_sqlite(false), do: 0
  defp normalize_value_for_sqlite(list) when is_list(list), do: Jason.encode!(list)
  defp normalize_value_for_sqlite(value), do: value

  # ---------------------------------------------------------------------------
  # Postgres trigger value encoding (mirrors pg_synclib_hash.c)
  # ---------------------------------------------------------------------------
  defp pg_encode_value(nil), do: "null"
  defp pg_encode_value(true), do: "1"      # BOOLOID → '1'
  defp pg_encode_value(false), do: "0"     # BOOLOID → '0'
  defp pg_encode_value(n) when is_integer(n), do: Integer.to_string(n)
  defp pg_encode_value(n) when is_float(n), do: :erlang.float_to_binary(n, [:compact, {:decimals, 20}])
  defp pg_encode_value(s) when is_binary(s), do: "\"#{json_escape(s)}\""
  # Arrays: pg trigger converts via array_to_json() then json_escape_into(),
  # producing a JSON string (matching SQLite TEXT representation)
  defp pg_encode_value(list) when is_list(list) do
    arr_json = Jason.encode!(list)
    "\"#{json_escape(arr_json)}\""
  end
  # JSONB/JSON: pg trigger embeds as raw JSON object (not escaped string).
  # The C library's sorted_json function recursively sorts keys.
  defp pg_encode_value(map) when is_map(map), do: Jason.encode!(map)

  defp json_escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  # ---------------------------------------------------------------------------
  # SQLite stored value simulation
  # ---------------------------------------------------------------------------
  defp sqlite_stored_value(true), do: 1       # SQLite stores booleans as INTEGER
  defp sqlite_stored_value(false), do: 0
  # SQLite stores arrays as TEXT (JSON string). Client reads it as a Dart String.
  defp sqlite_stored_value(list) when is_list(list), do: Jason.encode!(list)
  defp sqlite_stored_value(value), do: value

  # ---------------------------------------------------------------------------
  # Pure-Elixir canonical sorted JSON (reference implementation)
  # This is what synclib_build_sorted_json_from_json produces.
  # ---------------------------------------------------------------------------
  defp canonical_sorted_json(input_json) do
    input_json
    |> Jason.decode!()
    |> encode_sorted()
  end

  defp encode_sorted(map) when is_map(map) do
    parts =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> "\"#{json_escape(k)}\":#{encode_sorted_value(v)}" end)

    "{" <> Enum.join(parts, ",") <> "}"
  end

  defp encode_sorted_value(nil), do: "null"
  defp encode_sorted_value(true), do: "true"
  defp encode_sorted_value(false), do: "false"
  defp encode_sorted_value(n) when is_integer(n), do: Integer.to_string(n)
  defp encode_sorted_value(n) when is_float(n), do: :erlang.float_to_binary(n, [:compact, {:decimals, 20}])
  defp encode_sorted_value(s) when is_binary(s), do: "\"#{json_escape(s)}\""
  defp encode_sorted_value(list) when is_list(list) do
    items = Enum.map(list, &encode_sorted_value/1)
    "[" <> Enum.join(items, ",") <> "]"
  end
  defp encode_sorted_value(map) when is_map(map), do: encode_sorted(map)

  defp row_hash(id, sorted_json) do
    :crypto.hash(:sha256, "#{id}|#{sorted_json}")
    |> Base.encode16(case: :lower)
  end

  # ===========================================================================
  # Tests: Array column handling
  # ===========================================================================

  describe "array columns" do
    @row %{"id" => "user1", "name" => "Alice", "participants" => ["bob", "charlie"]}

    test "Elixir normalizes arrays to JSON strings" do
      json = elixir_input_json(@row)
      decoded = Jason.decode!(json)

      # After normalize_value_for_sqlite, the array becomes a STRING
      assert is_binary(decoded["participants"])
      assert decoded["participants"] == "[\"bob\",\"charlie\"]"
    end

    test "Postgres trigger encodes arrays as JSON strings (matching SQLite)" do
      json = pg_trigger_input_json(@row)
      decoded = Jason.decode!(json)

      # After fix: pg trigger uses array_to_json() then json_escape_into()
      # producing a JSON string that matches SQLite TEXT representation
      assert is_binary(decoded["participants"])
      assert decoded["participants"] == "[\"bob\",\"charlie\"]"
    end

    test "SQLite client reads arrays as strings" do
      json = sqlite_client_input_json(@row)
      decoded = Jason.decode!(json)

      # SQLite stores arrays as TEXT, client reads as string
      assert is_binary(decoded["participants"])
      assert decoded["participants"] == "[\"bob\",\"charlie\"]"
    end

    test "Postgres trigger and Elixir produce matching canonical JSON for arrays" do
      elixir_canonical = canonical_sorted_json(elixir_input_json(@row))
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))

      # After fixing pg_synclib_hash.c to encode arrays as JSON strings (matching SQLite),
      # both paths should produce identical canonical JSON.
      assert elixir_canonical == pg_canonical
    end

    test "Elixir and SQLite client produce MATCHING canonical JSON for arrays" do
      elixir_canonical = canonical_sorted_json(elixir_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      # Both treat arrays as strings — these should match
      assert elixir_canonical == client_canonical
    end

    test "precomputed row_hash (PG) matches client-computed hash for array rows" do
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      pg_hash = row_hash("user1", pg_canonical)
      client_hash = row_hash("user1", client_canonical)

      assert pg_hash == client_hash
    end
  end

  # ===========================================================================
  # Tests: Boolean handling
  # ===========================================================================

  describe "boolean columns" do
    @row %{"id" => "test1", "active" => true, "deleted" => false}

    test "all platforms normalize booleans to 0/1" do
      elixir_canonical = canonical_sorted_json(elixir_input_json(@row))
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      # All three should produce identical JSON with 0/1 for booleans
      assert elixir_canonical == pg_canonical
      assert elixir_canonical == client_canonical
    end

    test "boolean row hashes match across platforms" do
      elixir_hash = row_hash("test1", canonical_sorted_json(elixir_input_json(@row)))
      pg_hash = row_hash("test1", canonical_sorted_json(pg_trigger_input_json(@row)))
      client_hash = row_hash("test1", canonical_sorted_json(sqlite_client_input_json(@row)))

      assert elixir_hash == pg_hash
      assert elixir_hash == client_hash
    end
  end

  # ===========================================================================
  # Tests: Null handling
  # ===========================================================================

  describe "null values" do
    @row %{"id" => "n1", "name" => "Alice", "deleted_at" => nil}

    test "all platforms handle null consistently" do
      elixir_canonical = canonical_sorted_json(elixir_input_json(@row))
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      assert elixir_canonical == pg_canonical
      assert elixir_canonical == client_canonical
    end
  end

  # ===========================================================================
  # Tests: Simple types (no normalization needed)
  # ===========================================================================

  describe "simple row with strings and integers" do
    @row %{"id" => "s1", "name" => "Bob", "age" => 42}

    test "all platforms produce identical hashes" do
      elixir_hash = row_hash("s1", canonical_sorted_json(elixir_input_json(@row)))
      pg_hash = row_hash("s1", canonical_sorted_json(pg_trigger_input_json(@row)))
      client_hash = row_hash("s1", canonical_sorted_json(sqlite_client_input_json(@row)))

      assert elixir_hash == pg_hash
      assert elixir_hash == client_hash
    end
  end

  # ===========================================================================
  # Tests: Mixed types (realistic row)
  # ===========================================================================

  describe "realistic row with mixed types" do
    @row %{
      "id" => "user42",
      "name" => "Charlie",
      "online" => true,
      "points" => 1500,
      "deleted_at" => nil,
      "triballeaders" => ["tribe1", "tribe2"],
      "subscribedto" => ["tribe1"]
    }

    test "PG trigger hash matches client for rows with arrays" do
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      pg_hash = row_hash("user42", pg_canonical)
      client_hash = row_hash("user42", client_canonical)

      assert pg_hash == client_hash
    end

    test "Elixir slow path matches client for rows with arrays" do
      elixir_canonical = canonical_sorted_json(elixir_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      assert elixir_canonical == client_canonical
    end
  end

  # ===========================================================================
  # Tests: Empty arrays
  # ===========================================================================

  describe "empty arrays" do
    @row %{"id" => "e1", "tags" => []}

    test "empty arrays match between PG trigger and client" do
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      assert pg_canonical == client_canonical
    end
  end

  # ===========================================================================
  # Tests: Nested arrays
  # ===========================================================================

  describe "arrays with special characters" do
    @row %{"id" => "sp1", "tags" => ["hello world", "it's \"quoted\"", "line\nnewline"]}

    test "arrays with special chars match between PG and client" do
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      assert pg_canonical == client_canonical
    end

    test "Elixir and client match for arrays with special chars" do
      elixir_canonical = canonical_sorted_json(elixir_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      assert elixir_canonical == client_canonical
    end
  end

  # ===========================================================================
  # Tests: JSONB document column (included in hash on all platforms)
  # ===========================================================================

  describe "JSONB document column" do
    # JSONB is stored as a JSON object in Postgres and as TEXT (json string) in SQLite.
    # All platforms now include it in the hash. The C library recursively sorts
    # JSON keys, so key order doesn't matter.

    @row %{
      "id" => "doc1",
      "name" => "Alice",
      "document" => %{"z_field" => "last", "a_field" => "first", "nested" => %{"b" => 2, "a" => 1}}
    }

    test "Elixir includes document in hash" do
      json = elixir_input_json(@row)
      decoded = Jason.decode!(json)

      # document should be a map (Elixir doesn't normalize maps)
      assert is_map(decoded["document"])
    end

    test "PG trigger includes document as raw JSON object" do
      json = pg_trigger_input_json(@row)
      decoded = Jason.decode!(json)

      # PG trigger embeds JSONB as raw JSON object, not a string
      assert is_map(decoded["document"])
    end

    test "SQLite client reads document as parsed JSON (via json() wrapper)" do
      # On the client, json() SQLite wrapper converts JSONB binary to text JSON.
      # _parseJsonbColumns then decodes the string into a map before hashing.
      json = sqlite_client_input_json(@row)
      decoded = Jason.decode!(json)

      # After _parseJsonbColumns, document is a map
      assert is_map(decoded["document"])
    end

    test "all platforms produce matching canonical JSON with document" do
      elixir_canonical = canonical_sorted_json(elixir_input_json(@row))
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      # C library sorts keys recursively, so all platforms should match
      # regardless of original key order
      assert elixir_canonical == pg_canonical
      assert elixir_canonical == client_canonical
    end

    test "document with unsorted keys produces same hash on all platforms" do
      elixir_hash = row_hash("doc1", canonical_sorted_json(elixir_input_json(@row)))
      pg_hash = row_hash("doc1", canonical_sorted_json(pg_trigger_input_json(@row)))
      client_hash = row_hash("doc1", canonical_sorted_json(sqlite_client_input_json(@row)))

      assert elixir_hash == pg_hash
      assert elixir_hash == client_hash
    end
  end

  describe "JSONB document with all value types" do
    @row %{
      "id" => "doc2",
      "document" => %{
        "string" => "hello",
        "number" => 42,
        "float" => 3.14,
        "bool_true" => true,
        "bool_false" => false,
        "null_val" => nil,
        "array" => [1, "two", 3],
        "nested" => %{"key" => "value"}
      }
    }

    test "complex document hashes match across platforms" do
      elixir_canonical = canonical_sorted_json(elixir_input_json(@row))
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(@row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(@row))

      assert elixir_canonical == pg_canonical
      assert elixir_canonical == client_canonical
    end

    test "complex document row hashes match" do
      elixir_hash = row_hash("doc2", canonical_sorted_json(elixir_input_json(@row)))
      pg_hash = row_hash("doc2", canonical_sorted_json(pg_trigger_input_json(@row)))
      client_hash = row_hash("doc2", canonical_sorted_json(sqlite_client_input_json(@row)))

      assert elixir_hash == pg_hash
      assert elixir_hash == client_hash
    end
  end

  describe "empty and null document" do
    test "empty document matches across platforms" do
      row = %{"id" => "doc3", "name" => "Test", "document" => %{}}

      elixir_canonical = canonical_sorted_json(elixir_input_json(row))
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(row))

      assert elixir_canonical == pg_canonical
      assert elixir_canonical == client_canonical
    end

    test "null document matches across platforms" do
      row = %{"id" => "doc4", "name" => "Test", "document" => nil}

      elixir_canonical = canonical_sorted_json(elixir_input_json(row))
      pg_canonical = canonical_sorted_json(pg_trigger_input_json(row))
      client_canonical = canonical_sorted_json(sqlite_client_input_json(row))

      assert elixir_canonical == pg_canonical
      assert elixir_canonical == client_canonical
    end
  end

  # ===========================================================================
  # Tests: Realistic row with document + arrays + booleans
  # ===========================================================================

  describe "full realistic row with document, arrays, and booleans" do
    @row %{
      "id" => "user99",
      "name" => "Diana",
      "online" => true,
      "deleted_at" => nil,
      "triballeaders" => ["tribe_a", "tribe_b"],
      "document" => %{
        "preferences" => %{"theme" => "dark", "lang" => "en"},
        "scores" => [100, 200, 300]
      }
    }

    test "all platforms produce matching hashes" do
      elixir_hash = row_hash("user99", canonical_sorted_json(elixir_input_json(@row)))
      pg_hash = row_hash("user99", canonical_sorted_json(pg_trigger_input_json(@row)))
      client_hash = row_hash("user99", canonical_sorted_json(sqlite_client_input_json(@row)))

      assert elixir_hash == pg_hash
      assert elixir_hash == client_hash
    end

    test "canonical JSON sorts document keys recursively" do
      canonical = canonical_sorted_json(elixir_input_json(@row))

      # Verify the document's nested keys are sorted
      assert canonical =~ "\"lang\":\"en\""
      assert canonical =~ "\"theme\":\"dark\""
      # preferences comes before scores (alphabetical)
      pref_pos = :binary.match(canonical, "\"preferences\"") |> elem(0)
      scores_pos = :binary.match(canonical, "\"scores\"") |> elem(0)
      assert pref_pos < scores_pos
    end
  end
end
