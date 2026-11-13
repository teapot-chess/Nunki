defmodule NunkiWeb.AccessGate do
  @moduledoc """
  The door. Every page, the hall screen included, is behind the access PIN
  for any browser that is not on this machine; `/unlock` is where the PIN is
  given, and the static files are outside it.

    * `call/2` (a plug, in the `:gate` pipeline): this machine's own browser
      passes, and the session is marked `local` so that the LiveView, which
      sees only the session, knows. Anyone else needs a *stamp* in the
      session that equals the stamp of the PIN as it is now
      (`Nunki.AccessPin.stamp/0`); without one they are sent to `/unlock`.
    * `on_mount/4`: the same question again when the socket connects, so a
      grant voided by a change of PIN does not get a live page back. The
      session's `local` is recomputed from the connection on every request
      and signed with the secret key base; a remote browser cannot set it.

  A page that wants to know whether it is the machine's own screen reads the
  `:local?` assign this puts on the socket (and on the connection).
  """

  import Plug.Conn

  alias Nunki.AccessPin

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    local? = NunkiWeb.Local.request?(conn)
    conn = conn |> put_session("local", local?) |> assign(:local?, local?)

    if local? or AccessPin.granted?(get_session(conn, "pin_stamp")) do
      conn
    else
      conn
      |> remember_page()
      |> Phoenix.Controller.redirect(to: "/unlock")
      |> halt()
    end
  end

  @doc "`on_mount` for the live session."
  def on_mount(:default, _params, session, socket) do
    local? = session["local"] == true

    if local? or AccessPin.granted?(session["pin_stamp"]) do
      {:cont, Phoenix.Component.assign(socket, :local?, local?)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/unlock")}
    end
  end

  # A hall screen opened with its screen and/or tournament: `t=<id>`,
  # `screen=<name>`, either or both, and nothing else.
  defp hall_query?(query),
    do: query =~ ~r/\A(?:t|screen)=[A-Za-z0-9_\-]+(?:&(?:t|screen)=[A-Za-z0-9_\-]+)?\z/

  # Where to go once the PIN is given: one of our own pages, never what a
  # request said it wanted.
  defp remember_page(%Plug.Conn{method: "GET", request_path: path} = conn)
       when path in ["/", "/hall", "/help"] do
    page =
      if path == "/hall" and hall_query?(conn.query_string),
        do: path <> "?" <> conn.query_string,
        else: path

    put_session(conn, "return_to", page)
  end

  defp remember_page(conn), do: conn

  @doc "Where `/unlock` sends a browser that has just given the PIN."
  def return_path(conn) do
    case get_session(conn, "return_to") do
      "/hall?" <> query = page -> if hall_query?(query), do: page, else: "/"
      page when page in ["/", "/hall", "/help"] -> page
      _none -> "/"
    end
  end
end
