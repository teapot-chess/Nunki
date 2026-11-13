defmodule NunkiWeb.HallLiveTest do
  @moduledoc "The hall screen: idle, pairings, a countdown, its start, and the line being read."

  use Nunki.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nunki.{Countdown, Speaker, Store, TestClock}

  @endpoint NunkiWeb.Endpoint

  defp tournament(name, round \\ nil) do
    {:ok, id} =
      Store.add_tournament(%{
        "server" => "fake",
        "socket" => "ws://127.0.0.1:1/p/nunki/link/#{name}",
        "key" => "k",
        "tournament" => %{"id" => name, "name" => name}
      })

    if round, do: Store.update_tournament(id, &Map.put(&1, "round", round))
    id
  end

  test "nothing joined: a calm idle screen, with the Fullscreen button" do
    {:ok, view, _html} = live(local_conn(), "/hall")
    assert has_element?(view, "#hall-idle")
    assert has_element?(view, "#fullscreen[phx-hook]")
  end

  test "the latest pairings when there is no countdown" do
    tournament("Open A", payload(3))
    {:ok, view, _html} = live(local_conn(), "/hall")
    assert has_element?(view, "#hall-pairings")
    assert has_element?(view, "#board-1")
    assert has_element?(view, "#board-2 .hb-bye")
  end

  test "a countdown: the round and the minutes, then 'has started'" do
    id = tournament("Open A", payload(3))
    {:ok, _} = Countdown.start(id, 4, 300)
    {:ok, view, _html} = live(local_conn(), "/hall")

    assert has_element?(view, "#hall-countdown")
    assert view |> element("#hall-clock") |> render() =~ "5:00"

    TestClock.advance(300_000)
    Countdown.tick()
    eventually(fn -> has_element?(view, "#hall-started") end)
  end

  test "?t= picks a tournament; otherwise the one with a countdown" do
    a = tournament("Open A", payload(1))
    b = tournament("Open B", payload(2))
    {:ok, _} = Countdown.start(b, 3, 600)

    {:ok, view, _html} = live(local_conn(), "/hall")
    assert has_element?(view, "#hall-countdown")

    {:ok, view, _html} = live(local_conn(), "/hall?t=#{a}")
    assert has_element?(view, "#hall-pairings")
  end

  test "the tournament's language, not the page's" do
    tournament("Open A", payload(3, locale: "nl"))
    {:ok, _view, html} = live(local_conn(), "/hall")
    assert html =~ "Ronde 3"
  end

  test "the line being read is shown" do
    Fake.hold()
    tournament("Open A")
    {:ok, view, _html} = live(local_conn(), "/hall")
    Speaker.say(["Board 1: one against another."], "en")
    eventually(fn -> has_element?(view, "#hall-line") end)
  end

  test "an announcement is on the screen while it is news" do
    id = tournament("Open A", payload(3))
    {:ok, view, _html} = live(local_conn(), "/hall")
    refute has_element?(view, "#hall-announcement")

    Nunki.Announcer.announce(id, %{"id" => "x1", "text" => "Tea at four."})
    eventually(fn -> has_element?(view, "#hall-announcement", "Tea at four.") end)

    # An old one is not shown.
    Store.update_tournament(
      id,
      &put_in(&1, ["announcement", "at"], System.os_time(:second) - 600)
    )

    {:ok, view, _html} = live(local_conn(), "/hall")
    refute has_element?(view, "#hall-announcement")
  end

  describe "modes" do
    test "black: nothing at all, and it follows a change at once" do
      tournament("Open A", payload(3))
      {:ok, view, _html} = live(local_conn(), "/hall")
      assert has_element?(view, "#hall-pairings")

      Nunki.Hall.put_mode("hdmi1", "black")
      eventually(fn -> has_element?(view, "#hall-black") end)
      refute has_element?(view, "#hall-pairings")
      refute has_element?(view, "#fullscreen")

      assert view
             |> element("#hall-black")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.trim() == ""

      Nunki.Hall.put_mode("hdmi1", "live")
      eventually(fn -> has_element?(view, "#hall-pairings") end)
      assert has_element?(view, "#board-1")
    end

    test "paused: stays on what it showed, until live again" do
      id = tournament("Open A", payload(3))
      {:ok, view, _html} = live(local_conn(), "/hall")
      Nunki.Hall.put_mode("hdmi1", "paused")
      eventually(fn -> has_element?(view, "#hall[data-mode=paused]") end)

      {:ok, _} = Countdown.start(id, 4, 300)
      Store.update_tournament(id, &Map.put(&1, "round", payload(4)))
      _ = render(view)
      refute has_element?(view, "#hall-countdown")
      assert view |> element("#hall-pairings h1") |> render() =~ "Round 3"

      Nunki.Hall.put_mode("hdmi1", "live")
      eventually(fn -> has_element?(view, "#hall-countdown") end)
    end

    test "each screen has its own mode; ?screen= says which this is" do
      tournament("Open A", payload(3))
      Nunki.Hall.put_mode("hdmi2", "black")

      {:ok, one, _html} = live(local_conn(), "/hall")
      {:ok, two, _html} = live(local_conn(), "/hall?screen=hdmi2")
      assert has_element?(one, "#hall-pairings")
      assert has_element?(two, "#hall-black")

      Nunki.Hall.put_mode("hdmi1", "black")
      eventually(fn -> has_element?(one, "#hall-black") end)
      Nunki.Hall.put_mode("hdmi2", "live")
      eventually(fn -> has_element?(two, "#hall-pairings") end)
    end

    test "a screen's chosen tournament is shown without ?t=, and ?t= still beats it" do
      a = tournament("Open A", payload(1))
      b = tournament("Open B", payload(2))
      # The automatic pick is the first joined; choose the other one.
      {auto, other, other_round, auto_round} =
        if hd(Store.tournaments())["id"] == a,
          do: {a, b, "Round 2", "Round 1"},
          else: {b, a, "Round 1", "Round 2"}

      {:ok, view, _html} = live(local_conn(), "/hall")
      assert view |> element("#hall-pairings h1") |> render() =~ auto_round

      Nunki.Hall.put_tournament("hdmi1", other)
      eventually(fn -> view |> element("#hall-pairings h1") |> render() =~ other_round end)

      {:ok, view, _html} = live(local_conn(), "/hall?t=#{auto}")
      assert view |> element("#hall-pairings h1") |> render() =~ auto_round
    end

    test "identify: the screen's number, over anything, black included" do
      Nunki.Hall.put_mode("hdmi2", "black")
      {:ok, one, _html} = live(local_conn(), "/hall")
      {:ok, two, _html} = live(local_conn(), "/hall?screen=hdmi2")

      Nunki.Hall.identify()
      eventually(fn -> has_element?(one, "#hall-identify", "1") end)
      eventually(fn -> has_element?(two, "#hall-identify", "2") end)

      send(one.pid, :identify_done)
      eventually(fn -> not has_element?(one, "#hall-identify") end)
    end
  end
end
