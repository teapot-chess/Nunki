defmodule NunkiWeb.PinText do
  @moduledoc "What the pages say about a PIN that was refused, or that has to be waited for."

  use Gettext, backend: NunkiWeb.Gettext

  @doc "Why `Nunki.AccessPin.validate/1` said no, as a sentence."
  def invalid(:too_short), do: gettext("The PIN needs at least 6 characters.")
  def invalid(:too_long), do: gettext("The PIN may have 64 characters at most.")
  def invalid(:padded), do: gettext("The PIN may not start or end with a space.")

  def invalid(reason) when reason in [:control, :invalid_utf8],
    do: gettext("The PIN has a character that cannot be seen or typed.")

  def invalid(_other), do: gettext("That cannot be the PIN.")

  def wait(seconds), do: ngettext("Wait 1 second.", "Wait %{count} seconds.", seconds)
end
