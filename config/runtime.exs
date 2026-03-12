import Config

# Load .env file for local development
if config_env() == :dev do
  env_file = Path.join(File.cwd!(), ".env")
  if File.exists?(env_file) do
    File.read!(env_file)
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.each(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          clean_value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
          System.put_env(key, clean_value)
        _ -> :ok
      end
    end)
  end
end

# Dev: Override port and database if env vars are set
if config_env() == :dev do
  if port = System.get_env("PORT") do
    config :sync_server, SyncServerWeb.Endpoint,
      http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)]
  end

  if database_url = System.get_env("DATABASE_URL") do
    config :sync_server, SyncServer.Repo,
      url: database_url
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  database_ssl = System.get_env("DATABASE_SSL", "false") == "true"

  config :sync_server, SyncServer.Repo,
    url: database_url,
    ssl: database_ssl,
    socket_options: if(System.get_env("ECTO_IPV6") == "true", do: [:inet6], else: []),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4444")

  config :sync_server, SyncServerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
