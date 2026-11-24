defmodule Nunki.Join do
  @moduledoc """
  Joining a tournament: the whole of it is one link.

  OpenPairings' "Add an announcer" (the tournament's Settings, Hall
  announcer) shows `https://<server>/p/nunki/join/<code>`, as text and as a QR
  code, good for fifteen minutes and for one device. The operator pastes it
  into the control page and presses Join; Nunki POSTs to that very address
  who it is, and the answer is its own long key, where the link's socket
  is, what the server is called and which tournament this is. The key goes
  into `state.json` and is never shown.

  Anything before `/p/` is kept as it is, so OpenPairings behind a sub-path
  (`https://example.org/chess/p/nunki/join/...`) works. A print station's
  link (`/p/polis/join/...`) or a phone's (`manubrium://connect?...`) is
  refused before anything is sent: the code would be spent on the wrong
  device. The code itself is 43 characters of base64url, good once for
  fifteen minutes; any code is taken as it comes (older links had 16).

  Answers (hall-link-v1, `join-response` and `join-error`): 200 with `key`, `socket`, `server`,
  `tournament`; 404 or 410 a code that is unknown, used or expired; 409 a
  protocol version the server does not speak; anything else is not an
  OpenPairings server.
  """

  @version 1
  @product "nunki"

  def version, do: @version

  @doc """
  `{:ok, %{"server", "socket", "key", "tournament"}}` - what
  `Nunki.Store.add_tournament/1` takes - or `{:error, reason}` with
  `reason` one of `:not_a_link`, `:plain_http`, `{:other_product, name}`,
  `:used_or_expired`, `:version`, `:not_a_server`, `:unreachable`.
  """
  def redeem(link, identity, req_options \\ []) do
    with {:ok, uri} <- parse(link) do
      url = URI.to_string(%{uri | query: nil, fragment: nil})

      options =
        Keyword.merge(
          [
            json: identity,
            retry: false,
            receive_timeout: 15_000,
            connect_options: [timeout: 10_000]
          ],
          req_options
        )

      case Req.post(url, options) do
        {:ok,
         %{
           status: 200,
           body: %{"key" => key, "socket" => "/" <> _ = socket, "tournament" => %{"id" => _} = t}
         } = response}
        when is_binary(key) and key != "" ->
          {:ok,
           %{
             "server" => response.body["server"] || uri.host,
             "socket" => socket_url(uri, socket),
             "key" => key,
             "tournament" => %{"id" => t["id"], "name" => t["name"] || ""}
           }}

        {:ok, %{status: status}} when status in [404, 410] ->
          {:error, :used_or_expired}

        {:ok, %{status: 409}} ->
          {:error, :version}

        {:ok, _other} ->
          {:error, :not_a_server}

        {:error, _exception} ->
          {:error, :unreachable}
      end
    end
  end

  @doc """
  The join link's parts: `{:ok, uri}`, `{:error, {:other_product, name}}`
  for another hall app's link (a print station's `/p/polis/join/...`, or a
  phone's `manubrium://connect?...`), `{:error, :plain_http}` for `http://` to a host outside this network,
  or `{:error, :not_a_link}`. Nothing is
  sent for any of the errors, so a code is never spent on the wrong device.
  """
  def parse(link) when is_binary(link) do
    with {:ok, uri, _server, _code} <- read(link), do: {:ok, uri}
  end

  def parse(_other), do: {:error, :not_a_link}

  @doc """
  What a pairing link means (hall-link-v1, `pairing-link`): `{:ok, %{server,
  code}}`, the server's base URL (anything before the last `/p/` included)
  and the one-time code; or the errors of `parse/1`.
  """
  def pairing(link) when is_binary(link) do
    with {:ok, _uri, server, code} <- read(link), do: {:ok, %{server: server, code: code}}
  end

  def pairing(_other), do: {:error, :not_a_link}

  defp read(link) do
    case URI.new(String.trim(link)) do
      {:ok, %URI{scheme: "manubrium"}} ->
        {:error, {:other_product, "manubrium"}}

      {:ok, %URI{scheme: scheme, host: host, path: path} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_binary(path) ->
        with [before, rest] <- split_last(path),
             [product, "join", code] when code != "" <- String.split(rest, "/") do
          cond do
            scheme == "http" and not private_host?(host) -> {:error, :plain_http}
            product == @product -> {:ok, uri, server(uri, before), code}
            true -> {:error, {:other_product, product}}
          end
        else
          _other -> {:error, :not_a_link}
        end

      _other ->
        {:error, :not_a_link}
    end
  end

  @doc """
  Whether a host may be spoken to over plain http: loopback, a private
  address (RFC 1918, link-local, 100.64/10 as Tailscale uses it, fc00::/7,
  fe80::/10) or a `.local` / `.localhost` name. Anywhere else the device key
  would cross the open internet in clear, on the join and on every reconnect.
  """
  def private_host?(host) when is_binary(host) do
    host =
      host
      |> String.trim("[")
      |> String.trim("]")
      |> String.trim_trailing(".")
      |> String.downcase()

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b in 16..31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {100, b, _, _}} when b in 64..127 -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {a, _, _, _, _, _, _, _}} when a in 0xFC00..0xFDFF or a in 0xFE80..0xFEBF -> true
      {:ok, _public} -> false
      {:error, _name} -> host == "localhost" or String.ends_with?(host, [".local", ".localhost"])
    end
  end

  def private_host?(_host), do: false

  defp server(uri, ""),
    do: URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})

  defp server(uri, before),
    do: URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port, path: before})

  # The LAST "/p/" in the path: a sub-path may itself contain one.
  defp split_last(path) do
    case :binary.matches(path, "/p/") do
      [] ->
        :none

      matches ->
        {at, len} = List.last(matches)
        [binary_part(path, 0, at), binary_part(path, at + len, byte_size(path) - at - len)]
    end
  end

  # Where the socket is: the same host and port, ws for http, wss for https.
  defp socket_url(uri, path) do
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    URI.to_string(%URI{scheme: scheme, host: uri.host, port: uri.port, path: path})
  end
end
