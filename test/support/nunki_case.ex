defmodule Nunki.Case do
  @moduledoc """
  A clean Nunki for each test: no lines, no countdowns, nothing being said,
  a fresh state.json, the fake voices listed, the clock back at its start.
  Everything is the running application's own processes; the tests are
  not async, because there is one hall and one mouth.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Nunki.Case
      alias Nunki.Voice.Fake
    end
  end

  setup do
    reset!()
    on_exit(&reset!/0)
    :ok
  end

  def reset! do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Nunki.Links),
        do: DynamicSupervisor.terminate_child(Nunki.Links, pid)

    for {t, _} <- Nunki.Countdown.all(), do: Nunki.Countdown.cancel(t)
    Nunki.Speaker.stop()
    Nunki.Voice.Fake.reset()
    File.rm(Nunki.Paths.state_file())
    Nunki.Store.reload()
    Nunki.Voice.refresh(Nunki.Voice.Fake, %{})
    Nunki.TestClock.set(1_000_000)
    # A known PIN, and nobody locked out.
    :ok = Nunki.AccessPin.set(pin())
    Nunki.DoorGuard.reset()
    :ok
  end

  @doc "The PIN every test starts with."
  def pin, do: "246810"

  @doc "This machine's own browser: loopback peer, `Host: localhost`. Never asked for the PIN."
  def local_conn do
    Phoenix.ConnTest.build_conn() |> Map.put(:host, "localhost")
  end

  @doc """
  Another computer on the hall's network: a LAN peer address (`ip`, a tuple)
  asking for the host the station answers to in the tests. Asked for the PIN.
  """
  def remote_conn(ip \\ {192, 168, 1, 20}) do
    conn = Phoenix.ConnTest.build_conn()
    %{conn | remote_ip: ip}
  end

  @doc "Waits (by asking, never by sleeping) until `fun` is truthy; fails after `ms`."
  def eventually(fun, ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition never held")
        else
          # Let the processes involved get a turn; no fixed sleep.
          _ = :sys.get_state(Nunki.Store)
          _ = :sys.get_state(Nunki.Speaker)
          :erlang.yield()
          poll(fun, deadline)
        end

      value ->
        value
    end
  end

  @doc "A round payload as OpenPairings sends it."
  def payload(round, opts \\ []) do
    %{
      "tournament" => %{"id" => "t-1", "name" => "Fake Open", "city" => "Town", "dates" => ""},
      "round" => round,
      "rounds" => 7,
      "published_at" => "2026-10-17T10:00:00Z",
      "locale" => Keyword.get(opts, :locale, "en"),
      "rating_label" => "Elo",
      "team" => false,
      "rev" => Keyword.get(opts, :rev, 1),
      "boards" =>
        Keyword.get(opts, :boards, [
          %{
            "board" => "1",
            "white" => %{"name" => "Alpha, Ann", "spoken" => "Ann Alpha", "rating" => 2100},
            "black" => %{"name" => "Beta, Bob", "spoken" => "Bob Beta", "rating" => 2050},
            "bye" => nil
          },
          %{
            "board" => "2",
            "white" => %{"name" => "Gamma, Cee"},
            "black" => nil,
            "bye" => "pab"
          }
        ])
    }
  end
end
