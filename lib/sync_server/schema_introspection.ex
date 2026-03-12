defmodule SyncServer.SchemaIntrospection do
  @moduledoc """
  Introspects Postgres schema and converts to SQLite-compatible DDL.

  Used by SchemaManager to generate client migrations from the server's
  current database state.
  """

  alias SyncServer.Repo

  @doc """
  Get all tables in the public schema (excluding system tables).
  """
  def get_tables do
    query = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
      AND table_name NOT IN ('schema_migrations', '_metadata')
    ORDER BY table_name
    """

    case Repo.query(query) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &List.first/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get column information for a specific table.
  """
  def get_table_columns(table_name) do
    query = """
    SELECT
      column_name,
      data_type,
      is_nullable,
      column_default,
      character_maximum_length
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = $1
    ORDER BY ordinal_position
    """

    case Repo.query(query, [table_name]) do
      {:ok, %{rows: rows, columns: columns}} ->
        columns_data = Enum.map(rows, fn row ->
          Enum.zip(columns, row) |> Enum.into(%{})
        end)
        {:ok, columns_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get primary key columns for a table.
  """
  def get_primary_keys(table_name) do
    query = """
    SELECT a.attname AS column_name
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    JOIN pg_class c ON c.oid = i.indrelid
    WHERE c.relname = $1
      AND i.indisprimary
    ORDER BY array_position(i.indkey, a.attnum)
    """

    case Repo.query(query, [table_name]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &List.first/1)}
      {:error, _} -> {:ok, []}
    end
  end

  @doc """
  Get JSONB column names for a table.
  """
  def get_jsonb_columns(table_name) do
    case get_table_columns(table_name) do
      {:ok, columns} ->
        jsonb_cols = columns
          |> Enum.filter(fn col -> col["data_type"] in ["json", "jsonb"] end)
          |> Enum.map(fn col -> col["column_name"] end)
        {:ok, jsonb_cols}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get indexes for a table (excluding primary key).
  """
  def get_indexes(table_name) do
    query = """
    SELECT
      i.relname AS index_name,
      array_agg(a.attname ORDER BY array_position(ix.indkey, a.attnum)) AS column_names,
      ix.indisunique AS is_unique
    FROM pg_class t
    JOIN pg_index ix ON t.oid = ix.indrelid
    JOIN pg_class i ON i.oid = ix.indexrelid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
    WHERE t.relname = $1
      AND t.relkind = 'r'
      AND NOT ix.indisprimary
    GROUP BY i.relname, ix.indisunique
    """

    case Repo.query(query, [table_name]) do
      {:ok, %{rows: rows, columns: columns}} ->
        indexes = Enum.map(rows, fn row ->
          Enum.zip(columns, row) |> Enum.into(%{})
        end)
        {:ok, indexes}

      {:error, _} ->
        {:ok, []}
    end
  end

  @doc """
  Convert Postgres type to SQLite type.
  """
  def postgres_to_sqlite_type(pg_type) do
    case pg_type do
      type when type in ["integer", "int", "int4", "smallint", "bigint", "serial", "bigserial"] ->
        "INTEGER"

      type when type in ["text", "varchar", "character varying", "char", "character", "uuid"] ->
        "TEXT"

      type when type in ["real", "double precision", "numeric", "decimal", "float", "float4", "float8"] ->
        "REAL"

      "boolean" ->
        "INTEGER"

      type when type in ["json", "jsonb"] ->
        "BLOB"

      type when type in ["timestamp", "timestamp without time zone", "timestamp with time zone", "timestamptz"] ->
        "INTEGER"

      "date" ->
        "INTEGER"

      type when type in ["time", "time without time zone"] ->
        "INTEGER"

      "bytea" ->
        "BLOB"

      _ ->
        "TEXT"
    end
  end

  @doc """
  Generate SQLite CREATE TABLE statement from Postgres table.
  """
  def generate_create_table_sql(table_name) do
    with {:ok, columns} <- get_table_columns(table_name),
         {:ok, primary_keys} <- get_primary_keys(table_name) do

      column_definitions = Enum.map(columns, fn col ->
        name = col["column_name"]
        type = postgres_to_sqlite_type(col["data_type"])
        nullable = if col["is_nullable"] == "NO", do: "NOT NULL", else: ""
        default = format_default_value(col["column_default"])
        primary = if name in primary_keys and length(primary_keys) == 1, do: "PRIMARY KEY", else: ""

        [name, type, nullable, default, primary]
        |> Enum.filter(&(&1 != ""))
        |> Enum.join(" ")
      end)

      column_defs_with_pk =
        if length(primary_keys) > 1 do
          pk_constraint = "PRIMARY KEY (#{Enum.join(primary_keys, ", ")})"
          column_definitions ++ [pk_constraint]
        else
          column_definitions
        end

      sql = """
      CREATE TABLE IF NOT EXISTS #{table_name} (
        #{Enum.join(column_defs_with_pk, ",\n  ")}
      )
      """ |> String.trim()

      {:ok, sql}
    end
  end

  @doc """
  Generate CREATE INDEX statements for a table.
  """
  def generate_index_sqls(table_name) do
    {:ok, indexes} = get_indexes(table_name)

    sqls = Enum.map(indexes, fn index ->
      unique = if index["is_unique"], do: "UNIQUE ", else: ""
      columns = Enum.join(index["column_names"], ", ")
      "CREATE #{unique}INDEX IF NOT EXISTS #{index["index_name"]} ON #{table_name} (#{columns})"
    end)
    {:ok, sqls}
  end

  defp format_default_value(nil), do: ""
  defp format_default_value(default) do
    default = Regex.replace(~r/::[a-z\s]+$/i, default, "")

    cond do
      String.contains?(default, "nextval") -> ""
      String.contains?(default, "now()") -> "DEFAULT (strftime('%s', 'now'))"
      String.contains?(default, "CURRENT_TIMESTAMP") -> "DEFAULT (strftime('%s', 'now'))"
      String.starts_with?(default, "'") -> "DEFAULT #{default}"
      true -> "DEFAULT #{default}"
    end
  end

  @doc """
  Generate complete schema as a list of SQL statements.
  """
  def generate_full_schema do
    with {:ok, tables} <- get_tables() do
      sqls = Enum.flat_map(tables, fn table ->
        {:ok, create_table} = generate_create_table_sql(table)
        {:ok, indexes} = generate_index_sqls(table)
        [create_table | indexes]
      end)

      {:ok, sqls}
    end
  end
end
