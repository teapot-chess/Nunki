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
    {:ok, view, _html} = live(build_conn(), "/hall")
    assert has_element?(view, "#hall-idle")
    assert has_element?(view, "#fullscreen[phx-hook]")
  end

  test "the latest pairings when there is no countdown" do
    tournament("Open A", payload(3))
    {:ok, view, _html} = live(build_conn(), "/hall")
    assert has_element?(view, "#hall-pairings")
    assert has_element?(view, "#board-1")
    assert has_element?(view, "#board-2 .hb-bye")
  end

  test "a countdown: the round and the minutes, then 'has started'" do
    id = tournament("Open A", payload(3))
    {:ok, _} = Countdown.start(id, 4, 300)
    {:ok, view, _html} = live(build_conn(), "/hall")

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

    {:ok, view, _html} = live(build_conn(), "/hall")
    assert has_element?(view, "#hall-countdown")

    {:ok, view, _html} = live(build_conn(), "/hall?t=#{a}")
    assert has_element?(view, "#hall-pairings")
  end

  test "the tournament's language, not the page's" do
    tournament("Open A", payload(3, locale: "nl"))
    {:ok, _view, html} = live(build_conn(), "/hall")
    assert html =~ "Ronde 3"
  end

  test "the line being read is shown" do
    Fake.hold()
    tournament("Open A")
    {:ok, view, _html} = live(build_conn(), "/hall")
    Speaker.say(["Board 1: one against another."], "en")
    eventually(fn -> has_element?(view, "#hall-line") end)
  end

  test "an announcement is on the screen while it is news" do
    id = tournament("Open A", payload(3))
    {:ok, view, _html} = live(build_conn(), "/hall")
    refute has_element?(view, "#hall-announcement")

    Nunki.Announcer.announce(id, %{"id" => "x1", "text" => "Tea at four."})
    eventually(fn -> has_element?(view, "#hall-announcement", "Tea at four.") end)

    # An old one is not shown.
    Store.update_tournament(
      id,
      &put_in(&1, ["announcement", "at"], System.os_time(:second) - 600)
    )

    {:ok, view, _html} = live(build_conn(), "/hall")
    refute has_element?(view, "#hall-announcement")
  end
end
