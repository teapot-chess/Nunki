defmodule Nunki.Store.Advanced do
  @moduledoc """
  Whether "Show advanced features" starts on. A `state.json` that has no
  `settings.advanced` yet (every file from before the switch existed, and a
  brand-new one) gets the answer worked out once from what it already holds,
  and written down so it does not change by itself afterwards.

  On when the file contains something only an advanced feature sets: a chosen
  voice, update checks switched off, a renamed device, or a tournament with a
  room or an announcer name of its own. Otherwise off. Nobody loses what they
  use; everybody else gets the small page.
  """

  @doc "`data` with `settings.advanced` filled in (and the file rewritten, if it was not there)."
  def derive(data, path) do
    settings = data["settings"] || %{}

    if Map.has_key?(settings, "advanced") do
      data
    else
      data = put_in(data, ["settings", "advanced"], uses_advanced?(data))
      Nunki.Store.write(path, data)
      data
    end
  end

  @doc "Does the file hold a value that only an advanced feature sets?"
  def uses_advanced?(data) do
    settings = data["settings"] || %{}
    device_name = data["device_name"]

    voices? = (settings["voices"] || %{}) != %{}
    updates_off? = settings["update_check"] == "never"
    renamed? = is_binary(device_name) and device_name != hostname()

    tournament? =
      Enum.any?(Map.values(data["tournaments"] || %{}), fn t ->
        announcer = t["announcer"] || %{}
        room = announcer["room"]
        name = announcer["name"]

        (is_binary(room) and room != "") or (is_binary(name) and name != device_name)
      end)

    voices? or updates_off? or renamed? or tournament?
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
