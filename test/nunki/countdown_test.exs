defmodule Nunki.CountdownTest do
  @moduledoc """
  The countdown's milestones, on a clock the test moves by hand: only the
  ones still ahead, only the last when several are due at once, a
  restatement that announces nothing twice, and a cancel that is quiet.
  """

  use Nunki.Case, async: false

  alias Nunki.{Countdown, Store, TestClock}

  setup do
    {:ok, id} =
      Store.add_tournament(%{
        "server" => "fake",
        "socket" => "ws://127.0.0.1:1/p/nunki/link",
        "key" => "k",
        "tournament" => %{"id" => "t-1", "name" => "Fake Open"}
      })

    %{t: id}
  end

  defp at(seconds_left_of_15_minutes) do
    # The countdown below starts at 15 minutes on a clock at 1_000_000.
    TestClock.set(1_000_000 + (900 - seconds_left_of_15_minutes) * 1000)
    Countdown.tick()
  end

  defp said, do: Fake.texts()

  test "ten, five, one and zero, each once, at its moment", %{t: t} do
    {:ok, _} = Countdown.start(t, 4, 900, source: :local)
    assert said() == []

    at(601)
    assert said() == []
    at(600)
    eventually(fn -> said() == ["Round 4 starts in ten minutes."] end)

    at(300)
    at(299)
    at(60)
    at(0)

    eventually(fn ->
      said() == [
        "Round 4 starts in ten minutes.",
        "Round 4 starts in five minutes.",
        "Round 4 starts in one minute. Please go to your board.",
        "Round 4 starts now. Please start the clocks."
      ]
    end)

    assert %{round: 4, started?: true, remaining_ms: 0} = Countdown.get(t)
    refute Countdown.running?()
  end

  test "only the milestones still ahead: a start at five minutes says five at once", %{t: t} do
    {:ok, _} = Countdown.start(t, 2, 300)
    eventually(fn -> said() == ["Round 2 starts in five minutes."] end)
    refute "Round 2 starts in ten minutes." in said()
  end

  test "a clock that jumped past several says only the last of them", %{t: t} do
    {:ok, _} = Countdown.start(t, 4, 900)
    at(30)
    eventually(fn -> said() == ["Round 4 starts in one minute. Please go to your board."] end)
  end

  test "a restatement with the same id moves the end and repeats nothing", %{t: t} do
    {:ok, "c1"} = Countdown.start(t, 4, 900, id: "c1", source: :server)
    at(600)
    eventually(fn -> length(said()) == 1 end)

    # The server says it again after a reconnect: 590 seconds left now.
    {:ok, "c1"} = Countdown.start(t, 4, 590, id: "c1", source: :server)
    Countdown.tick()
    assert %{remaining_ms: 590_000} = Countdown.get(t)
    assert length(said()) == 1
  end

  test "a restatement after zero does not start the round twice", %{t: t} do
    {:ok, "c1"} = Countdown.start(t, 4, 5, id: "c1")
    TestClock.advance(5_000)
    Countdown.tick()
    eventually(fn -> List.last(said()) == "Round 4 starts now. Please start the clocks." end)

    {:ok, "c1"} = Countdown.start(t, 4, 0, id: "c1")
    Countdown.tick()
    assert Enum.count(said(), &(&1 =~ "starts now")) == 1
  end

  test "cancel: by id only when it is that one; then nothing more is said", %{t: t} do
    {:ok, "c1"} = Countdown.start(t, 4, 900, id: "c1")
    Countdown.cancel(t, "other")
    assert Countdown.get(t)

    Countdown.cancel(t, "c1")
    assert Countdown.get(t) == nil
    at(0)
    assert said() == []
  end

  test "a started countdown lingers ten minutes for the hall screen, then goes", %{t: t} do
    {:ok, _} = Countdown.start(t, 4, 0)
    assert %{started?: true} = Countdown.get(t)

    TestClock.advance(10 * 60_000 - 1)
    Countdown.tick()
    assert Countdown.get(t)

    TestClock.advance(1)
    Countdown.tick()
    assert Countdown.get(t) == nil
  end

  test "every change is broadcast", %{t: t} do
    Nunki.subscribe()
    {:ok, _} = Countdown.start(t, 4, 900)
    assert_receive {:countdown, ^t}
  end

  test "the minutes the control page offers" do
    assert Countdown.local_choices() == [1, 2, 5, 10, 15, 20, 30]
  end
end
