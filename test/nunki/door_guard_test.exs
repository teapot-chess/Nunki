defmodule Nunki.DoorGuardTest do
  @moduledoc "The lockout: five free, then 5 s doubling to a quarter of an hour, and a cap for the box."

  use Nunki.Case, async: false

  alias Nunki.DoorGuard

  @ip {192, 168, 1, 20}

  defp fail(ip, now) do
    assert {:ok, _at} = DoorGuard.claim(ip, now)
  end

  test "four wrong guesses cost nothing, the fifth starts the wait" do
    for _ <- 1..4, do: fail(@ip, 0)
    assert {:ok, 0} = DoorGuard.claim(@ip, 0)
    assert {:wait, 5} = DoorGuard.claim(@ip, 0)
    assert {:wait, 2} = DoorGuard.claim(@ip, 3)
  end

  test "each failure after the wait doubles it, up to a quarter of an hour" do
    for _ <- 1..5, do: fail(@ip, 0)

    {_, waits} =
      Enum.reduce(1..12, {0, []}, fn _, {now, waits} ->
        {:wait, w} = DoorGuard.claim(@ip, now)
        now = now + w
        fail(@ip, now)
        {now, [w | waits]}
      end)

    waits = Enum.reverse(waits)
    assert Enum.take(waits, 4) == [5, 10, 20, 40]
    assert Enum.max(waits) == 900
  end

  test "the right PIN is refused while the address waits" do
    for _ <- 1..5, do: fail(@ip, 0)
    # The caller never compares: it is told to wait before it gets that far.
    assert {:wait, _seconds} = DoorGuard.claim(@ip, 1)
  end

  test "another address is not held up by it" do
    for _ <- 1..5, do: fail(@ip, 0)
    assert {:ok, _} = DoorGuard.claim({192, 168, 1, 21}, 0)
  end

  test "a right guess clears the address" do
    for _ <- 1..4, do: fail(@ip, 0)
    {:ok, at} = DoorGuard.claim(@ip, 0)
    DoorGuard.succeeded(@ip, at)

    for _ <- 1..4, do: fail(@ip, 0)
    assert {:ok, _} = DoorGuard.claim(@ip, 0)
    assert {:wait, _} = DoorGuard.claim(@ip, 0)
  end

  test "the box takes 40 failures a minute from anybody, then those who failed wait" do
    for n <- 1..40, do: fail({10, 0, 0, n}, 100)

    assert {:wait, 60} = DoorGuard.claim({10, 0, 0, 1}, 100)
    assert {:wait, 11} = DoorGuard.claim({10, 0, 0, 2}, 149)
    assert {:ok, _} = DoorGuard.claim({10, 0, 0, 3}, 160)
  end

  test "at the box-wide cap an address that has not failed still gets 2 tries of its own" do
    for n <- 1..40, do: fail({10, 0, 0, n}, 100)
    fresh = {10, 0, 2, 1}

    assert {:ok, _} = DoorGuard.claim(fresh, 100)
    assert {:ok, _} = DoorGuard.claim(fresh, 100)
    assert {:wait, _} = DoorGuard.claim(fresh, 100)
    # An address that had failed before the cap gets none.
    assert {:wait, _} = DoorGuard.claim({10, 0, 0, 3}, 100)
  end

  test "a right guess gives back its own failure, not another address's at the same second" do
    for n <- 1..39, do: fail({10, 0, 0, n}, 100)
    {:ok, at} = DoorGuard.claim({10, 0, 0, 40}, 100)
    # The cap is reached; the one who was right hands its own back.
    DoorGuard.succeeded({10, 0, 0, 40}, at)
    assert {:ok, _} = DoorGuard.claim({10, 0, 0, 2}, 100)
  end

  test "a right guess does not count against the box" do
    for n <- 1..39, do: fail({10, 0, 0, n}, 100)
    {:ok, at} = DoorGuard.claim({10, 0, 0, 99}, 100)
    DoorGuard.succeeded({10, 0, 0, 99}, at)
    assert {:ok, _} = DoorGuard.claim({10, 0, 0, 100}, 100)
  end

  test "an address quiet for an hour is forgotten" do
    for _ <- 1..5, do: fail(@ip, 0)
    assert {:wait, _} = DoorGuard.claim(@ip, 1)
    assert {:ok, _} = DoorGuard.claim(@ip, 3_700)
  end
end
