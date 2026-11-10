defmodule Nunki.DoorGuard do
  @moduledoc """
  Keeps the access PIN from being guessed. Without a limit, six digits fall
  in an afternoon.

  Failures are counted per address (the socket's, never a header) and for
  the whole box. An address gets five free tries; from the fifth failure on
  it waits 5 seconds, then 10, 20 and so on, up to a quarter of an hour, and
  even the right PIN is refused while it waits. Across all addresses the box
  takes at most 40 failures a minute; past that everybody who has already
  failed, right PIN included, waits until the oldest failure of that minute is
  a minute old. An address that has not failed yet still gets 2 tries of its
  own, so one phone guessing in a loop cannot keep the arbiter's laptop out.
  A right PIN clears its address's count. An address quiet for an hour is
  forgotten. The counts live in memory: a restart forgives everybody, which
  is no worse than the attacker waiting.

  A guess is counted *before* it is compared (`claim/2`), through this one
  process, so a burst of simultaneous guesses cannot all slip past a count
  that none of them has recorded yet. A right guess hands its claim back
  (`succeeded/2`).
  """

  use Agent

  @free 5
  @base 5
  @cap 900
  @global_limit 40
  @reserve 2
  @window 60
  @forget 3_600

  def start_link(_opts) do
    Agent.start_link(fn -> %{ips: %{}, global: []} end, name: __MODULE__)
  end

  @doc """
  Takes one guess for `ip`: `{:ok, claimed_at}` (go on and compare; it counts as a failure
  until `succeeded/2` says otherwise), or `{:wait, seconds}`. If the counter
  is not there to ask, nobody guesses.
  """
  @spec claim(term(), integer()) :: {:ok, integer()} | {:wait, pos_integer()}
  def claim(ip, now \\ now()) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = prune(state, now)

      case wait(state, ip, now) do
        {:reserve, 0} -> {{:ok, now}, count(state, ip, now, false)}
        {_kind, 0} -> {{:ok, now}, count(state, ip, now, true)}
        {_kind, wait} -> {{:wait, wait}, state}
      end
    end)
  catch
    :exit, _reason -> {:wait, @cap}
  end

  @doc "The guess claimed at `claimed_at` was right: the address starts again, the box's count forgets it."
  def succeeded(ip, claimed_at \\ now()) do
    Agent.update(__MODULE__, fn state ->
      %{
        state
        | ips: Map.delete(state.ips, ip),
          global: List.delete(state.global, {claimed_at, ip})
      }
    end)
  end

  @doc "Forgets everything (for tests)."
  def reset, do: Agent.update(__MODULE__, fn _state -> %{ips: %{}, global: []} end)

  @doc "Seconds, on the clock `claim/2` uses."
  def now, do: System.monotonic_time(:second)

  # `global?` false: one of the spare tries at the box-wide cap, not counted
  # against the box.
  defp count(state, ip, now, global?) do
    old = state.ips[ip] || %{fails: 0, reserved: 0}
    fails = old.fails + 1
    until = if fails >= @free, do: now + min(@base * Integer.pow(2, fails - @free), @cap)
    reserved = if global?, do: old.reserved, else: old.reserved + 1

    %{
      state
      | ips: Map.put(state.ips, ip, %{fails: fails, last: now, until: until, reserved: reserved}),
        global: if(global?, do: [{now, ip} | state.global], else: state.global)
    }
  end

  # {:normal | :reserve, seconds}: :reserve is an address with no failures of
  # its own (or still inside its two spare tries) while the box-wide cap holds.
  defp wait(state, ip, now) do
    own = ip_wait(state, ip, now)

    case global_wait(state, now) do
      0 ->
        {:normal, own}

      global ->
        if own == 0 and reserve?(state.ips[ip]),
          do: {:reserve, 0},
          else: {:normal, max(global, own)}
    end
  end

  defp reserve?(nil), do: true
  defp reserve?(%{reserved: used}), do: used > 0 and used < @reserve
  defp reserve?(_old), do: false

  defp ip_wait(state, ip, now) do
    case state.ips[ip] do
      %{until: until} when is_integer(until) -> max(until - now, 0)
      _none -> 0
    end
  end

  defp global_wait(%{global: times}, now) do
    if length(times) >= @global_limit,
      do:
        max(
          times |> Enum.map(&elem(&1, 0)) |> Enum.min() |> Kernel.+(@window) |> Kernel.-(now),
          0
        ),
      else: 0
  end

  defp prune(state, now) do
    ips =
      state.ips
      |> Enum.reject(fn {_ip, %{last: last, until: until}} ->
        now - last > @forget and (until || now) <= now
      end)
      |> Map.new()

    %{state | ips: ips, global: Enum.filter(state.global, fn {at, _ip} -> at > now - @window end)}
  end
end
