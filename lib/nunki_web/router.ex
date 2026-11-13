defmodule NunkiWeb.Router do
  use NunkiWeb, :router

  # No accounts, one access PIN: Nunki listens on this machine only, unless
  # NUNKI_LISTEN=lan says otherwise, and then every other computer on the
  # hall's network has to give the PIN (`NunkiWeb.AccessGate`) before any
  # page, the hall screen included. This machine's own browser is never asked.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NunkiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug NunkiWeb.Locale
  end

  # The door itself, and the language switch it shows: outside the gate.
  pipeline :gate do
    plug NunkiWeb.AccessGate
  end

  scope "/", NunkiWeb do
    pipe_through :browser

    get "/unlock", UnlockController, :show
    post "/unlock", UnlockController, :create

    # A form, not a link, so nothing a prefetching browser follows changes it.
    post "/locale", LocaleController, :set
  end

  # The local control API (docs/local-api.md): this machine's own programs
  # only - no session, no CSRF token, no PIN, because nobody else gets in.
  pipeline :local_api do
    plug NunkiWeb.Plugs.LocalOnly
  end

  scope "/api/local/v1", NunkiWeb do
    pipe_through :local_api

    get "/state", LocalApiController, :state
    post "/screen", LocalApiController, :screen
    post "/audio", LocalApiController, :audio
    post "/hall_tournament", LocalApiController, :hall_tournament
    post "/identify", LocalApiController, :identify
    post "/stop", LocalApiController, :stop
  end

  # Every page, behind the gate: the plug for the first request, `on_mount`
  # for the socket.
  scope "/", NunkiWeb do
    pipe_through [:browser, :gate]

    live_session :default,
      on_mount: [{NunkiWeb.AccessGate, :default}, {NunkiWeb.Locale, :default}] do
      live "/", ControlLive, :index
      live "/hall", HallLive, :index
      live "/help", HelpLive, :index
    end
  end
end
