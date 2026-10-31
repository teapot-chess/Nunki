defmodule NunkiWeb.Words do
  @moduledoc """
  The sentences the pages build from Nunki's answers: why a line is down,
  why a join failed, how long is left. In one place so the control page and
  the hall screen say the same thing the same way.
  """
  use Gettext, backend: NunkiWeb.Gettext

  @doc "Milliseconds as m:ss (or h:mm:ss past the hour); never negative."
  def clock(ms) when is_integer(ms) do
    total = div(max(ms, 0) + 999, 1000)
    {h, m, s} = {div(total, 3600), div(rem(total, 3600), 60), rem(total, 60)}

    if h > 0,
      do: "#{h}:#{pad(m)}:#{pad(s)}",
      else: "#{m}:#{pad(s)}"
  end

  def clock(_other), do: "0:00"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "Why a join failed, in a sentence."
  def join_error(:not_a_link),
    do: gettext("That is not a join link. Copy the whole link from OpenPairings and try again.")

  def join_error({:other_product, "manubrium"}),
    do:
      gettext(
        "That link is for Manubrium, the phone app: scan it with the phone. For Nunki, make an announcer link in OpenPairings (the tournament's Settings → Hall announcer)."
      )

  def join_error({:other_product, product}),
    do:
      gettext(
        "That link is for %{product}, not for Nunki. Ask OpenPairings for an announcer link.",
        product: String.capitalize(to_string(product))
      )

  def join_error(:used_or_expired),
    do: gettext("That link has been used or has expired. Make a new one in OpenPairings.")

  def join_error(:version),
    do: gettext("That server speaks a different version of the hall protocol. Update Nunki.")

  def join_error(:not_a_server),
    do: gettext("That address does not answer like OpenPairings does.")

  def join_error(:unreachable),
    do: gettext("Could not reach the server. Check the link and the network.")

  def join_error(_other), do: gettext("Joining did not work.")

  @doc "Why a line is down, or nil when there is nothing to say."
  def link_error(nil), do: nil
  def link_error(:nobody_answers), do: gettext("Nothing answers at that address.")
  def link_error(:no_such_address), do: gettext("That address does not exist (DNS).")
  def link_error(:timeout), do: gettext("The server takes too long to answer.")
  def link_error(:closed), do: gettext("The server closed the line.")
  def link_error(:silent), do: gettext("The server went silent.")

  def link_error(:not_a_server),
    do: gettext("That address does not answer like OpenPairings does.")

  def link_error({:refused, "version"}),
    do: gettext("The server speaks a different version. Update Nunki.")

  def link_error({:refused, "key"}),
    do:
      gettext(
        "The server does not know this device any more. Remove the tournament and join again."
      )

  def link_error({:refused, _other}), do: gettext("The server refused the line.")
  def link_error(_other), do: gettext("The line is down. Trying again.")

  @doc "Bytes in megabytes, one decimal."
  def megabytes(bytes) when is_integer(bytes),
    do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MB"

  def megabytes(_unknown), do: nil

  @doc "What an update would interrupt, in words."
  def busy(reasons) do
    Enum.map_join(reasons, " ", fn
      :countdown -> gettext("A countdown is running.")
      :speaking -> gettext("Nunki is speaking.")
    end)
  end
end
