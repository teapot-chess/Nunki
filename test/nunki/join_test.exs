defmodule Nunki.JoinTest do
  @moduledoc """
  The one step: a link in, a tournament joined. A link used, expired, for
  another program or pointing at nothing is said in words, and nothing is
  stored.
  """

  use Nunki.Case, async: false

  alias Nunki.{FakeServer, Join, Store, Tournaments}

  test "a join link: /p/nunki/join/<code>, any prefix, http or https" do
    assert {:ok, %URI{host: "pairings.example"}} =
             Join.parse(" https://pairings.example/p/nunki/join/K7Q-4MD ")

    assert {:ok, _} = Join.parse("https://example.org/chess/p/nunki/join/K7Q")
    assert {:ok, _} = Join.parse("https://example.org/p/x/p/nunki/join/K7Q")
    assert Join.parse("https://pairings.example/p/nunki/join/") == {:error, :not_a_link}
    assert Join.parse("https://pairings.example/tournaments") == {:error, :not_a_link}
    assert Join.parse("K7Q-4MD") == {:error, :not_a_link}
    assert Join.parse("ftp://x/p/nunki/join/K7Q") == {:error, :not_a_link}
    assert Join.parse(nil) == {:error, :not_a_link}
  end

  test "a good link joins: the key is fetched and kept, never shown" do
    server = FakeServer.start()
    assert {:ok, id} = Tournaments.join(FakeServer.link(server))

    assert [%{"id" => ^id, "server" => "fake", "tournament" => %{"name" => "Fake Open"}} = t] =
             Store.tournaments()

    refute Map.has_key?(t, "key")
    assert Store.key(id) == FakeServer.get(server, :key)
    assert t["socket"] == "ws://127.0.0.1:#{server.port}/op/p/nunki/link"

    # The server was told who joined.
    assert %{"v" => 1, "device" => device, "name" => _, "software" => "nunki " <> _} =
             FakeServer.get(server, :joined)

    assert device == Store.device_id()
  end

  test "a code works once; the second time is used or expired" do
    server = FakeServer.start()
    assert {:ok, _} = Tournaments.join(FakeServer.link(server))
    assert Tournaments.join(FakeServer.link(server)) == {:error, :used_or_expired}
    assert length(Store.tournaments()) == 1
  end

  test "an unknown code is used or expired too" do
    server = FakeServer.start()
    assert Tournaments.join(FakeServer.link(server, "NOPE")) == {:error, :used_or_expired}
    assert Store.tournaments() == []
  end

  test "a print station's link is refused before the code is spent" do
    server = FakeServer.start()

    assert Tournaments.join(FakeServer.link(server, "K7Q-4MD", "polis")) ==
             {:error, {:other_product, "polis"}}

    assert FakeServer.get(server, :joined) == nil
    assert MapSet.member?(FakeServer.get(server, :codes), "K7Q-4MD")
  end

  test "409 is a version the server does not speak; anything else is not a server" do
    server = FakeServer.start()
    FakeServer.set(server, :join_status, 409)
    assert Tournaments.join(FakeServer.link(server)) == {:error, :version}

    FakeServer.set(server, :join_status, 500)
    assert Tournaments.join(FakeServer.link(server)) == {:error, :not_a_server}
    assert Store.tournaments() == []
  end

  test "nobody at the address is unreachable" do
    server = FakeServer.start() |> FakeServer.down()
    assert Tournaments.join(FakeServer.link(server)) == {:error, :unreachable}
    assert Store.tournaments() == []
  end

  test "plain http only inside this network: elsewhere the key would travel in clear" do
    for link <- [
          "http://pairings.example/p/nunki/join/K7Q",
          "http://8.8.8.8/p/nunki/join/K7Q",
          "http://172.32.0.1/p/nunki/join/K7Q",
          "http://pairings.local.evil.example/p/nunki/join/K7Q"
        ] do
      assert Join.parse(link) == {:error, :plain_http}, link
    end

    for link <- [
          "https://pairings.example/p/nunki/join/K7Q",
          "http://localhost:4000/p/nunki/join/K7Q",
          "http://127.0.0.1:4000/p/nunki/join/K7Q",
          "http://192.168.1.20/p/nunki/join/K7Q",
          "http://10.0.0.5/p/nunki/join/K7Q",
          "http://100.101.102.103/p/nunki/join/K7Q",
          "http://[fd7a:115c:a1e0::1]/p/nunki/join/K7Q",
          "http://club-pc.local/p/nunki/join/K7Q"
        ] do
      assert {:ok, _} = Join.parse(link), link
    end

    assert NunkiWeb.Words.join_error(:plain_http) =~ "https://"
  end
end
