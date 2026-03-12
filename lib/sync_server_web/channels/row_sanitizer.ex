defmodule SyncServerWeb.RowSanitizer do
  @moduledoc """
  Default row sanitizer — passes all rows through unchanged.

  Override this by setting `config :sync_server, :row_sanitizer, MyApp.RowSanitizer`
  and implementing a module with `sanitize_row/4`.

  ## Example Custom Sanitizer

      defmodule MyApp.RowSanitizer do
        def sanitize_row(row, "secret_table", _claims, _client_id), do: nil
        def sanitize_row(row, _table, _claims, _client_id), do: row
      end
  """

  @doc """
  Sanitize a row before sending to the client.

  Return `nil` to exclude the row entirely.

  ## Parameters
  - `row` - The Ecto struct or map
  - `table` - Table name as string
  - `claims` - JWT claims map
  - `client_id` - The client's ID
  """
  def sanitize_row(row, _table, _claims, _client_id), do: row
end
