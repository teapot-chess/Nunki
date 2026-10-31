defmodule OpenPairingsNunkiWeb.JoinPlug do
  @moduledoc """
  `POST /p/nunki/join/:code`: an announcer spending its one-time join code.

  JSON in (`{"v":1,"device","name","software"}`), JSON out:

    * `200 {"key","socket","server","tournament":{"id","name"}}` - joined.
      The key is shown here once and stored only as its hash.
    * `404` - no such code. `410` - used or run out. `409` - a protocol
      version this plugin does not speak. `400` - not the JSON it should
      be. `429` - too many wrong codes from this address.

  No pipeline in front of it (`PairingsEngine.Plugin`, `http_routes/0`):
  the code is the only credential, and it is 256 random bits that live for
  fifteen minutes. The rate limit is there so a guesser pays for each
  guess anyway.
  """
  @behaviour Plug

  import Plug.Conn

  alias OpenPairingsNunki.{Hall, Protocol}
  alias PairingsEngine.RateLimit

  @max_body 8_000
  # A shared bucket of the core's, under a key of our own: refused codes
  # from one address, the same job it does for the board link.
  @bucket :board_link_auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    limit_key = "nunki_join:" <> PairingsEngineWeb.ClientIp.get(conn)

    if RateLimit.allow?(@bucket, limit_key) do
      conn |> answer(limit_key) |> halt()
    else
      conn |> json(429, %{error: "too_many_attempts"}) |> halt()
    end
  end

  defp answer(conn, limit_key) do
    with {:ok, %{} = params, conn} <- params(conn),
         :ok <- version(params),
         {:ok, attrs} <- attrs(params) do
      case Hall.redeem_join_code(conn.path_params["code"] || "", attrs) do
        {:ok, %{key: key, tournament: t}} ->
          RateLimit.clear(@bucket, limit_key)

          json(conn, 200, %{
            key: key,
            socket: Hall.socket_path(),
            server: Hall.server_name(),
            tournament: %{id: t.id, name: t.name}
          })

        {:error, :not_found} ->
          RateLimit.record(@bucket, limit_key)
          json(conn, 404, %{error: "unknown_code"})

        {:error, reason} when reason in [:used, :expired] ->
          RateLimit.record(@bucket, limit_key)
          json(conn, 410, %{error: to_string(reason)})
      end
    else
      {:error, :version} -> json(conn, 409, %{error: "version", v: Protocol.version()})
      {:more, _partial, conn} -> json(conn, 400, %{error: "too_large"})
      _ -> json(conn, 400, %{error: "bad_request"})
    end
  end

  # The endpoint's Plug.Parsers has normally read the JSON already (the
  # router is behind it); a body it let through unread (another content
  # type) is read and decoded here, with a ceiling.
  defp params(%Plug.Conn{body_params: %{} = params} = conn)
       when not is_struct(params) and map_size(params) > 0 and
              not is_map_key(params, "_json"),
       do: {:ok, params, conn}

  defp params(conn) do
    case read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{} = params} -> {:ok, params, conn}
          _ -> {:error, :bad_request}
        end

      other ->
        other
    end
  end

  defp version(%{"v" => v}), do: if(Protocol.accepts?(v), do: :ok, else: {:error, :version})
  defp version(_params), do: {:error, :version}

  defp attrs(%{"device" => device} = params) when is_binary(device) and device != "" do
    {:ok,
     %{
       "device" => device,
       "name" => string(params["name"]),
       "software" => string(params["software"])
     }}
  end

  defp attrs(_params), do: {:error, :bad_request}

  defp string(v) when is_binary(v), do: v
  defp string(_v), do: ""

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
