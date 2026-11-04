defmodule NunkiWeb.Local do
  @moduledoc """
  Whether a request is this machine's own browser, which is never asked for
  the access PIN and the only one that is shown it.

  All three must hold: the peer address is a loopback address, the `Host`
  names only this machine, and no proxy header says the request came from
  anywhere else. The address alone is not enough: a web page open in a
  browser on this machine can point its own name at 127.0.0.1 once it has
  loaded (DNS rebinding), and a reverse proxy on this machine makes every
  visitor a loopback peer.
  """

  import Plug.Conn

  @forwarding ~w(x-forwarded-for forwarded x-real-ip cf-connecting-ip x-forwarded-host)

  @spec request?(Plug.Conn.t()) :: boolean()
  def request?(conn) do
    loopback?(conn.remote_ip) and own_host?(conn.host) and not forwarded?(conn)
  end

  defp forwarded?(conn), do: Enum.any?(@forwarding, &(get_req_header(conn, &1) != []))

  @doc "Whether `host` (a `Host` header without its port) names this machine and nothing else."
  @spec own_host?(term()) :: boolean()
  def own_host?(host) when is_binary(host) do
    host = host |> String.trim_trailing(".") |> String.downcase()

    host in ["localhost", "::1", "[::1]"] or String.ends_with?(host, ".localhost") or
      loopback_literal?(host) or host in machine_names()
  end

  def own_host?(_host), do: false

  defp loopback_literal?(host) do
    case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
      {:ok, address} -> loopback?(address)
      _not_ipv4 -> false
    end
  end

  # `:inet.gethostname/0` always answers `{:ok, name}`.
  defp machine_names do
    {:ok, name} = :inet.gethostname()
    name = name |> to_string() |> String.downcase()
    [name, name <> ".local"]
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, 32_512, _}), do: true
  defp loopback?(_other), do: false
end
