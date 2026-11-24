defmodule NunkiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :nunki

  @session_options [
    store: :cookie,
    key: "_nunki_key",
    signing_salt: "Hk3vR8pQ",
    same_site: "Lax"
  ]

  # Before everything: a request that names a host this program does not
  # answer to (DNS rebinding) gets a 403 and nothing else. See the plug.
  plug NunkiWeb.HostGuard

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # The favicon is the mark (`NunkiWeb.Logo`), made from priv/logo/mark.svg,
  # so it is answered here and not read from priv/static.
  plug :favicon

  plug Plug.Static,
    at: "/",
    from: :nunki,
    gzip: not code_reloading?,
    only: NunkiWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  # The launcher's Details panel - this machine, a secret, no proxy header, or
  # a 404. Before the request logger, so a panel left open does not log its
  # own polling into the log it shows. See the plug.
  plug NunkiWeb.Plugs.LauncherStats

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["*/*"]

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug NunkiWeb.Router

  @doc false
  # sobelow_skip ["XSS.SendResp"]
  def favicon(%Plug.Conn{request_path: "/favicon.svg"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("image/svg+xml")
    |> Plug.Conn.put_resp_header("cache-control", "public, max-age=3600")
    |> Plug.Conn.send_resp(200, NunkiWeb.Logo.favicon())
    |> Plug.Conn.halt()
  end

  def favicon(conn, _opts), do: conn
end
