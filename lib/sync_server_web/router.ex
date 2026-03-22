defmodule SyncServerWeb.Router do
  use SyncServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_cors do
    plug :accepts, ["json"]
    plug SyncServerWeb.Plugs.CORS
  end

  # Health check
  scope "/", SyncServerWeb do
    pipe_through :api
    get "/health", HealthController, :index
  end

  scope "/api", SyncServerWeb do
    pipe_through :api_cors
    get "/health", HealthController, :index
  end

  if Mix.env() == :dev do
    scope "/api", SyncServerWeb do
      pipe_through :api_cors
      options "/test/items", TestController, :options
      options "/test/items/:id", TestController, :options
      delete "/test/items", TestController, :delete_all_items
      get "/test/items/:id", TestController, :get_item
      put "/test/items/:id", TestController, :update_item
      delete "/test/items/:id", TestController, :delete_item
    end
  end
end
