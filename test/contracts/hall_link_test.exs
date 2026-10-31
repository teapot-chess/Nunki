defmodule Nunki.Contracts.HallLinkTest do
  @moduledoc """
  OpenPairings' `hall-link-v1` (vendored), from Nunki's side: every pairing
  link the contract shows is read as it says; every join request and frame
  Nunki sends fits its schema; every answer and frame the contract has for
  an announcer is taken by the real `Nunki.Join` and `Nunki.Link`. And the
  fake OpenPairings the other tests talk to is held to the same schemas: a
  fake that drifts from the real thing proves nothing about it.
  """

  use Nunki.Case, async: false

  alias Nunki.{Contract, FakeServer, Join, Link, Store, Tournaments}

  # The frames a server sends an announcer; Polis's are not ours to take.
  @server_frames ~w(server-welcome server-settings-nunki server-round server-countdown
                    server-countdown-cancel server-read server-stop server-pong)

  defp joined(opts \\ []) do
    server = FakeServer.start()
    FakeServer.set(server, :on_welcome, Keyword.get(opts, :on_welcome, []))
    {:ok, id} = Tournaments.join(FakeServer.link(server))
    eventually(fn -> Link.info(id).up? end)
    {server, id}
  end

  describe "pairing links" do
    for {"pairing-link", name, example} <- Contract.examples() do
      @example example
      test name do
        case @example["app"] do
          "nunki" ->
            assert Join.pairing(@example["link"]) ==
                     {:ok, %{server: @example["server"], code: @example["code"]}}

          other ->
            assert Join.pairing(@example["link"]) == {:error, {:other_product, other}}
            assert Join.parse(@example["link"]) == {:error, {:other_product, other}}
        end
      end
    end

    test "another app's link is said in words, and nothing is sent" do
      for {"pairing-link", _name, %{"app" => app} = example} <- Contract.examples(),
          app != "nunki" do
        assert {:error, {:other_product, ^app}} = Tournaments.join(example["link"])
        assert NunkiWeb.Words.join_error({:other_product, app}) =~ String.capitalize(app)
      end

      assert Store.tournaments() == []
    end
  end

  describe "joining" do
    defp redeem_against(status, body) do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end

      Join.redeem(
        "https://pairings.cloud/p/nunki/join/" <> Contract.example("pairing-link.nunki")["code"],
        %{"v" => 1, "device" => "d-1", "name" => "PC", "software" => "nunki 0"},
        plug: plug
      )
    end

    test "every join-response example joins" do
      for {_name, body} <- Contract.examples("join-response") do
        assert {:ok, %{"key" => key, "socket" => "wss://pairings.cloud/" <> _}} =
                 redeem_against(200, body)

        assert key == body["key"]
      end
    end

    test "every join-error example, at the status the contract gives it, is the right refusal" do
      status = %{
        "bad_request" => 400,
        "too_large" => 400,
        "unknown_code" => 404,
        "used" => 410,
        "expired" => 410,
        "version" => 409,
        "too_many_attempts" => 429
      }

      expected = %{404 => :used_or_expired, 410 => :used_or_expired, 409 => :version}

      for {_name, %{"error" => error} = body} <- Contract.examples("join-error") do
        code = Map.fetch!(status, error)
        assert redeem_against(code, body) == {:error, Map.get(expected, code, :not_a_server)}
      end
    end

    test "what Nunki posts is a join-request, and the fake answers a join-response" do
      server = FakeServer.start()
      {:ok, _id} = Tournaments.join(FakeServer.link(server))
      Contract.assert_valid!("join-request", FakeServer.get(server, :joined))

      Contract.assert_valid!("join-response", %{
        "key" => FakeServer.get(server, :key),
        "socket" => "/op/p/nunki/link",
        "server" => "fake",
        "tournament" => %{"id" => 1, "name" => "Fake Open"}
      })
    end
  end

  describe "the line" do
    test "hello, status, settings and leave as Nunki sends them" do
      {server, id} = joined()

      eventually(fn -> FakeServer.frames(server, "status") != [] end)
      [hello] = FakeServer.frames(server, "hello")
      Contract.assert_valid!("device-hello", hello)

      for status <- FakeServer.frames(server, "status"),
          do: Contract.assert_valid!("device-status-nunki", status)

      assert :ok = Tournaments.change_settings(id, "Door PC", "Foyer")
      eventually(fn -> FakeServer.frames(server, "settings") != [] end)

      for settings <- FakeServer.frames(server, "settings"),
          do: Contract.assert_valid!("device-settings-nunki", settings)

      Tournaments.remove(id)
      eventually(fn -> FakeServer.frames(server, "leave") != [] end)

      for leave <- FakeServer.frames(server, "leave"),
          do: Contract.assert_valid!("device-leave", leave)
    end

    test "every server frame for an announcer is taken, and the line stays up" do
      {server, id} = joined()

      for schema <- @server_frames, {_name, frame} <- Contract.examples(schema) do
        FakeServer.push(server, frame)
      end

      eventually(fn -> Store.tournament(id)["announcer"]["rooms_available"] != nil end)
      assert Store.tournament(id)["announcer"]["rooms_available"] == ["Main hall", "Annex"]
      _ = :sys.get_state(Link.whereis(id))
      assert Link.info(id).up?
    end

    for schema <- ~w(server-leave server-refused) do
      @schema schema
      test "#{schema}: every example ends the line as the contract says" do
        for {_name, frame} <- Contract.examples(@schema) do
          {server, id} = joined()
          if frame["reason"] == "revoked", do: FakeServer.set(server, :revoked, true)
          FakeServer.push(server, frame)

          case frame do
            %{"reason" => reason} when reason in ["key", "version"] ->
              eventually(fn -> Link.info(id).error == {:refused, reason} end)
              assert Store.tournament(id)

            _forget ->
              eventually(fn -> Store.tournament(id) == nil end)
          end

          Tournaments.remove(id)
        end
      end
    end
  end
end
