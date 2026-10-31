defmodule Nunki.LinkTest do
  @moduledoc """
  The line to a tournament, against a fake OpenPairings: hello and welcome,
  a round read once, commands obeyed, a removal that forgets, a reconnect
  that restates.
  """

  use Nunki.Case, async: false

  alias Nunki.{Countdown, FakeServer, Link, Speaker, Store, Tournaments}

  defp joined(opts \\ []) do
    server = FakeServer.start()
    FakeServer.set(server, :on_welcome, Keyword.get(opts, :on_welcome, []))
    {:ok, id} = Tournaments.join(FakeServer.link(server))
    eventually(fn -> Link.info(id).up? end)
    {server, id}
  end

  test "hello carries the key; welcome brings the line up and a status goes back" do
    {server, id} = joined()

    assert [hello] = FakeServer.frames(server, "hello")
    assert hello["key"] == Store.key(id)
    assert hello["v"] == 1
    assert hello["device"] == Store.device_id()

    eventually(fn -> FakeServer.frames(server, "status") != [] end)

    assert [%{"voice" => "Fake English (en-GB)", "speaking" => false} | _] =
             FakeServer.frames(server, "status")

    assert Tournaments.links_up() == 1
  end

  describe "name and room (settings)" do
    test "what the server says is kept per tournament, and what it says next replaces it" do
      {server, id} =
        joined(on_welcome: [%{"type" => "settings", "name" => "Hall PC", "room" => "Main hall"}])

      eventually(fn -> Store.tournament(id)["announcer"] end)
      assert Store.tournament(id)["announcer"] == %{"name" => "Hall PC", "room" => "Main hall"}

      FakeServer.push(server, %{"type" => "settings", "name" => "Side PC", "room" => ""})
      eventually(fn -> Store.tournament(id)["announcer"]["name"] == "Side PC" end)
      assert Store.tournament(id)["announcer"]["room"] == ""
    end

    test "a change asked for here is sent, and stored only when the server answers" do
      {server, id} =
        joined(on_welcome: [%{"type" => "settings", "name" => "Hall PC", "room" => "Main hall"}])

      eventually(fn -> Store.tournament(id)["announcer"] end)

      assert :ok = Tournaments.change_settings(id, "  Door PC ", " Foyer ")
      eventually(fn -> FakeServer.frames(server, "settings") != [] end)

      assert [%{"type" => "settings", "name" => "Door PC", "room" => "Foyer"}] =
               FakeServer.frames(server, "settings")

      assert Store.tournament(id)["announcer"] == %{"name" => "Hall PC", "room" => "Main hall"}

      FakeServer.push(server, %{"type" => "settings", "name" => "Door PC", "room" => "Foyer"})
      eventually(fn -> Store.tournament(id)["announcer"]["room"] == "Foyer" end)
    end

    test "the rooms the server offers are kept; an older server's frame has none" do
      {server, id} =
        joined(
          on_welcome: [
            %{
              "type" => "settings",
              "name" => "Hall PC",
              "room" => "Main hall",
              "rooms_available" => ["Main hall", "Annex"]
            }
          ]
        )

      eventually(fn -> Store.tournament(id)["announcer"] end)

      assert Store.tournament(id)["announcer"] == %{
               "name" => "Hall PC",
               "room" => "Main hall",
               "rooms_available" => ["Main hall", "Annex"]
             }

      # A frame without the key is an older server: no list, free text.
      FakeServer.push(server, %{"type" => "settings", "name" => "Hall PC", "room" => ""})
      eventually(fn -> Store.tournament(id)["announcer"]["room"] == "" end)
      refute Map.has_key?(Store.tournament(id)["announcer"], "rooms_available")
    end

    test "a refused room is announced, and the frame still counts as the server's word" do
      {server, id} = joined()
      Nunki.subscribe()

      FakeServer.push(server, %{
        "type" => "settings",
        "name" => "Hall PC",
        "room" => "Annex",
        "rooms_available" => ["Annex"],
        "error" => "room"
      })

      assert_receive {:room_refused, ^id}, 2_000
      assert Store.tournament(id)["announcer"]["room"] == "Annex"
    end

    test "an empty name is not asked for; an empty room is" do
      {server, id} = joined()
      assert :ok = Tournaments.change_settings(id, "   ", "")
      eventually(fn -> FakeServer.frames(server, "settings") != [] end)

      assert [%{"type" => "settings", "room" => ""} = frame] =
               FakeServer.frames(server, "settings")

      refute Map.has_key?(frame, "name")
    end

    test "with no line there is nobody to ask" do
      {:ok, id} =
        Store.add_tournament(%{
          "server" => "fake",
          "socket" => "ws://127.0.0.1:1/p/nunki/link",
          "key" => "k",
          "tournament" => %{"id" => "t-9", "name" => "Nowhere Open"}
        })

      assert {:error, :down} = Tournaments.change_settings(id, "Name", "Room")
    end
  end

  test "a new round is read once; the same round changed is not read again" do
    {server, id} = joined()

    FakeServer.push(server, %{"type" => "round", "round" => payload(3)})
    eventually(fn -> "Board 1: Ann Alpha against Bob Beta." in Fake.texts() end)
    eventually(fn -> not Speaker.speaking?() end)
    count = length(Fake.texts())

    FakeServer.push(server, %{"type" => "round", "round" => payload(3, rev: 2)})
    eventually(fn -> Store.tournament(id)["round"]["rev"] == 2 end)
    assert length(Fake.texts()) == count

    # "read" from the server reads it again, on purpose.
    FakeServer.push(server, %{"type" => "read", "round" => 3})
    eventually(fn -> length(Fake.texts()) == 2 * count end)
  end

  test "read on publish switched off: kept, not read" do
    Store.put_setting("read_on_publish", false)
    {server, id} = joined()

    FakeServer.push(server, %{"type" => "round", "round" => payload(1)})
    eventually(fn -> Store.tournament(id)["round"] != nil end)
    assert Fake.texts() == []
  end

  test "the tournament's language, unless the control page overrides it" do
    {server, _id} = joined()
    FakeServer.push(server, %{"type" => "round", "round" => payload(2, locale: "nl")})
    eventually(fn -> "De indeling van ronde 2 is bekend." in Fake.texts() end)

    Fake.reset()
    Store.put_setting("language", "en")
    FakeServer.push(server, %{"type" => "round", "round" => payload(3, locale: "nl")})
    eventually(fn -> "Pairings for round 3 are published." in Fake.texts() end)
  end

  test "countdown, countdown_cancel and stop are obeyed" do
    {server, id} = joined()

    FakeServer.push(server, %{
      "type" => "countdown",
      "round" => 5,
      "seconds_left" => 300,
      "id" => 9
    })

    eventually(fn -> Countdown.get(id) end)
    assert %{round: 5, id: "9", source: :server, remaining_ms: 300_000} = Countdown.get(id)
    eventually(fn -> "Round 5 starts in five minutes." in Fake.texts() end)

    FakeServer.push(server, %{"type" => "countdown_cancel", "id" => 9})
    eventually(fn -> Countdown.get(id) == nil end)

    Fake.hold()
    Speaker.say(["a long line", "and another"], "en")
    eventually(fn -> Speaker.speaking?() end)
    FakeServer.push(server, %{"type" => "stop"})
    eventually(fn -> not Speaker.speaking?() end)
    assert Speaker.status().queued == 0
  end

  test "announce is said once, in the tournament's language, and kept for the screens" do
    {server, id} = joined()

    FakeServer.push(server, %{"type" => "round", "round" => payload(2, locale: "nl")})
    eventually(fn -> "De indeling van ronde 2 is bekend." in Fake.texts() end)
    Fake.reset()

    frame = %{"type" => "announce", "id" => "a1", "canned" => "silence"}
    FakeServer.push(server, frame)
    eventually(fn -> "Stilte alstublieft." in Fake.texts() end)
    assert %{"id" => "a1", "text" => "Stilte alstublieft."} = Store.tournament(id)["announcement"]

    # The same id again (a frame delivered twice) is not said twice.
    FakeServer.push(server, frame)

    FakeServer.push(server, %{
      "type" => "announce",
      "id" => "a2",
      "text" => "Boards 1-5 to the desk."
    })

    eventually(fn -> "Boards 1-5 to the desk." in Fake.texts() end)
    assert Enum.count(Fake.texts(), &(&1 == "Stilte alstublieft.")) == 1
  end

  test "speaking is reported to the server" do
    {server, _id} = joined()
    Fake.hold()
    Speaker.say(["hello"], "en")
    eventually(fn -> Enum.any?(FakeServer.frames(server, "status"), & &1["speaking"]) end)
    Fake.finish()
    eventually(fn -> List.last(FakeServer.frames(server, "status"))["speaking"] == false end)
  end

  test "revoked in OpenPairings: forgotten here too" do
    {server, id} = joined()
    FakeServer.set(server, :revoked, true)
    FakeServer.push(server, %{"type" => "refused", "reason" => "revoked"})

    eventually(fn -> Store.tournament(id) == nil end)
    eventually(fn -> Link.whereis(id) == nil end)
  end

  test "leave from the server: forgotten, and its countdown with it" do
    {server, id} = joined()
    {:ok, _} = Countdown.start(id, 2, 900)
    FakeServer.push(server, %{"type" => "leave"})

    eventually(fn -> Store.tournament(id) == nil end)
    assert Countdown.get(id) == nil
  end

  test "an unknown key is said on the page and the tournament is kept" do
    {server, id} = joined()
    FakeServer.set(server, :key, "another")
    FakeServer.down(server) |> FakeServer.up()

    eventually(fn -> Link.info(id).error == {:refused, "key"} end, 5_000)
    assert Store.tournament(id)
  end

  test "Remove here tells the server" do
    {server, id} = joined()
    Tournaments.remove(id)
    eventually(fn -> FakeServer.frames(server, "leave") != [] end)
    assert Store.tournament(id) == nil
  end

  test "a reconnect says hello again, and the server's restatement repeats nothing" do
    countdown = %{"type" => "countdown", "round" => 3, "seconds_left" => 300, "id" => "c7"}
    {server, id} = joined(on_welcome: [countdown])

    eventually(fn -> "Round 3 starts in five minutes." in Fake.texts() end)

    FakeServer.down(server)
    eventually(fn -> not Link.info(id).up? end)
    FakeServer.up(server)

    eventually(fn -> length(FakeServer.frames(server, "hello")) == 2 end, 5_000)
    eventually(fn -> Link.info(id).up? end)
    _ = :sys.get_state(Countdown)
    assert Enum.count(Fake.texts(), &(&1 == "Round 3 starts in five minutes.")) == 1
    assert %{id: "c7"} = Countdown.get(id)
  end
end
