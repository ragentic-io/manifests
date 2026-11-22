defmodule ManifestsWeb.Router do
  use ManifestsWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ManifestsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :public_cors
  end

  # The signed transport ragentic's registry client reads. No content
  # negotiation: whatever the client asks for, it gets the signed bytes.
  scope "/", ManifestsWeb do
    get "/healthz", RegistryController, :healthz
    get "/v1/index.json", RegistryController, :index
    get "/v1/browse-index.json", RegistryController, :browse_index
    get "/v1/bundles/:digest", RegistryController, :bundle
    get "/v1/browse-bundles/:digest", RegistryController, :browse_bundle
    get "/v1/items-index.json", RegistryController, :items_index
    get "/v1/item-bundles/:digest", RegistryController, :item_bundle
  end

  scope "/api/v1", ManifestsWeb.Api do
    pipe_through :api

    get "/manifests", ManifestController, :index
    get "/labels", ManifestController, :labels
    get "/manifests/:id", ManifestController, :show
    get "/manifests/:id/bundle", ManifestController, :bundle
    get "/manifests/:id/versions", ManifestController, :versions

    get "/items", ItemController, :index
    get "/items/:id", ItemController, :show
    get "/items/:id/versions", ItemController, :versions
    get "/items/:id/bundle", ItemController, :bundle
  end

  scope "/", ManifestsWeb do
    pipe_through :browser

    live "/", CatalogLive, :index
    live "/apps/:id", ManifestLive, :show
    live "/items", ItemsLive, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:manifests, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ManifestsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/" do
      pipe_through :browser

      oban_dashboard("/oban")
    end
  end

  # Read-only and unauthenticated, so any site may call it.
  defp public_cors(conn, _) do
    Plug.Conn.put_resp_header(conn, "access-control-allow-origin", "*")
  end

  if Application.compile_env(:manifests, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
