defmodule NunkiWeb.Plugs.LocalOnly do
  @moduledoc """
  The door of the local control API (`/api/local/v1`, docs/local-api.md):
  programs on this machine, and nobody else, whatever the PIN or
  `NUNKI_LISTEN` say. There is no PIN on the API because there is no
  stranger to ask it of.

  Refused with a 403 and `{"error": ...}`:

    * a peer that is not a loopback address (127.0.0.0/8, ::1);
    * a request that a proxy on this machine passed on (`X-Forwarded-For`
      and friends, `tailscale serve`'s own headers): that loopback peer is
      somebody else;
    * a request with an `Origin` that is not one of Nunki's own names: a web
      page in a browser on this machine, which may send a request but not
      choose its origin. (`NunkiWeb.HostGuard` has already refused any
      `Host` that is not ours, which is what stops DNS rebinding.)
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not NunkiWeb.Local.loopback?(conn.remote_ip) ->
        refuse(conn, "only programs on this machine may use this API")

      NunkiWeb.Local.forwarded?(conn) ->
        refuse(conn, "a request passed on by a proxy is not one from this machine")

      not origin_ok?(conn) ->
        refuse(conn, "a web page may not use this API")

      true ->
        conn
    end
  end

  defp origin_ok?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> NunkiWeb.HostGuard.origin_allowed?(URI.parse(origin))
      _several -> false
    end
  end

  defp refuse(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{"error" => message}))
    |> halt()
  end
end
