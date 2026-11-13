defmodule NunkiWeb.TailnetTest do
  @moduledoc """
  `NunkiWeb.Tailnet` and `NunkiWeb.HostGuard`: this machine's own Tailscale
  name and addresses are answered with NUNKI_LISTEN=lan, and nothing else on
  the tailnet is.
  """

  use Nunki.Case, async: false

  import Phoenix.ConnTest

  alias NunkiWeb.{HostGuard, Tailnet}

  @endpoint NunkiWeb.Endpoint

  @status %{
    "Self" => %{
      "DNSName" => "Hall-Pi.example-tailnet.ts.net.",
      "HostName" => "hall-pi",
      "TailscaleIPs" => ["100.101.102.103", "fd7a:115c:a1e0::1234"]
    },
    "Peer" => %{
      "x" => %{"DNSName" => "laptop.example-tailnet.ts.net.", "TailscaleIPs" => ["100.64.0.9"]}
    }
  }

  setup do
    Application.put_env(:nunki, :listen, :lan)

    on_exit(fn ->
      Application.delete_env(:nunki, :listen)
      Tailnet.put_names([])
    end)
  end

  test "from_status takes this machine and never a peer" do
    assert Tailnet.from_status(@status) == [
             "hall-pi.example-tailnet.ts.net",
             "hall-pi",
             "100.101.102.103",
             "fd7a:115c:a1e0::1234"
           ]

    assert Tailnet.from_status(%{}) == []
    assert Tailnet.from_status("nonsense") == []
  end

  test "the MagicDNS name and the tailnet address are answered once Tailscale says so" do
    refute HostGuard.host_allowed?("hall-pi.example-tailnet.ts.net")

    Tailnet.put_names(Tailnet.from_status(@status))

    assert HostGuard.host_allowed?("hall-pi.example-tailnet.ts.net")
    assert HostGuard.host_allowed?("HALL-PI.example-tailnet.ts.net.")
    assert HostGuard.host_allowed?("[fd7a:115c:a1e0::1234]")
    assert HostGuard.host_allowed?("100.101.102.103")

    conn = build_conn() |> Map.put(:host, "hall-pi.example-tailnet.ts.net") |> get("/help")
    # Through the host check; then the PIN door, as for any other computer.
    assert conn.status in [200, 302]
  end

  test "another name on the tailnet, or any other .ts.net name, is still refused" do
    Tailnet.put_names(Tailnet.from_status(@status))
    refute HostGuard.host_allowed?("laptop.example-tailnet.ts.net")
    refute HostGuard.host_allowed?("100.64.0.9")
    refute HostGuard.host_allowed?("evil.ts.net")
  end

  test "on loopback the tailnet names do not count" do
    Tailnet.put_names(Tailnet.from_status(@status))
    Application.put_env(:nunki, :listen, :loopback)
    refute HostGuard.host_allowed?("hall-pi.example-tailnet.ts.net")
  end
end
