defmodule NunkiWeb.HostGuard do
  @moduledoc """
  Which host names this station answers to, for the HTTP request (a plug) and
  for the LiveView socket (`check_origin`).

  The station has no login. What kept a stranger out was the address:
  127.0.0.1, or the hall's network when `POLIS_LISTEN=lan`. A web page in the
  hall PC's own browser walks round that with DNS rebinding: its host name is
  pointed at 127.0.0.1 after the page has loaded, the browser then considers
  `http://that-name:4061` the same origin as the page, and the page's script
  drives the control page as if it were the operator. The two checks here
  close it, because the name the browser asked for is the one thing the page
  cannot choose:

    * `call/2` answers 403 to any request whose `Host` header is not on the
      list;
    * `origin_allowed?/1` gives the socket the same list as its `check_origin`.

  The list is `localhost`, `127.0.0.1`, `::1`, the host in the endpoint's `url`
  (`PHX_HOST`), and, only when `config :nunki, listen: :lan` says the station
  was told to listen on the network, this machine's own host name (also with
  `.local`) and every address of its interfaces. `config :nunki, extra_hosts: [...]`
  adds names for the tests.
  """
  @behaviour Plug

  import Plug.Conn

  @loopback ~w(localhost 127.0.0.1 ::1)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if host_allowed?(conn.host) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(
        403,
        "Forbidden: Nunki does not answer to the name " <>
          "#{conn.host}. Use localhost or this machine's address, " <>
          "or set PHX_HOST to that name."
      )
      |> halt()
    end
  end

  @doc "`check_origin` callback: the origin's host must be one this station answers to."
  @spec origin_allowed?(URI.t()) :: boolean()
  def origin_allowed?(%URI{host: host}), do: host_allowed?(host)

  @doc "Whether `host` (as in a Host header, port already removed) is one of ours."
  @spec host_allowed?(String.t() | nil) :: boolean()
  def host_allowed?(host) when is_binary(host), do: normalize(host) in allowed_hosts()
  def host_allowed?(_host), do: false

  @doc "Every host name this station answers to right now."
  @spec allowed_hosts() :: [String.t()]
  def allowed_hosts do
    configured = Application.get_env(:nunki, NunkiWeb.Endpoint, [])[:url][:host]
    extra = Application.get_env(:nunki, :extra_hosts, [])
    base = @loopback ++ List.wrap(configured) ++ extra
    base = if Application.get_env(:nunki, :listen) == :lan, do: base ++ lan_hosts(), else: base
    Enum.map(base, &normalize/1)
  end

  @doc "This machine's own names and interface addresses (the hall's network)."
  @spec lan_hosts() :: [String.t()]
  def lan_hosts do
    names =
      case :inet.gethostname() do
        {:ok, name} -> [to_string(name), to_string(name) <> ".local"]
        _ -> []
      end

    addresses =
      case :inet.getifaddrs() do
        {:ok, interfaces} ->
          for {_name, opts} <- interfaces,
              {:addr, addr} <- opts,
              do: addr |> :inet.ntoa() |> to_string()

        _ ->
          []
      end

    names ++ addresses
  end

  # Host headers carry brackets around an IPv6 address, case does not matter,
  # and a fully qualified name may end in a dot.
  defp normalize(host) do
    host |> String.trim("[") |> String.trim("]") |> String.trim_trailing(".") |> String.downcase()
  end
end
