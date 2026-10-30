defmodule Nunki.AdvancedSettingTest do
  @moduledoc "An existing state.json decides once whether advanced features start on."

  use Nunki.Case, async: false

  alias Nunki.{Paths, Store}

  defp write_state(settings, extra \\ %{}) do
    {:ok, host} = :inet.gethostname()

    data =
      Map.merge(
        %{
          "version" => 1,
          "device_id" => "dev",
          "device_name" => to_string(host),
          "tournaments" => %{},
          "settings" => settings
        },
        extra
      )

    File.write!(Paths.state_file(), Jason.encode!(data))
    Store.reload()
  end

  test "a new box starts with advanced off" do
    refute Store.setting("advanced")
  end

  test "an old box with nothing custom stays off, and says so in the file" do
    write_state(%{"language" => "nl"})
    assert Store.setting("advanced") == false

    assert Paths.state_file()
           |> File.read!()
           |> Jason.decode!()
           |> get_in(["settings", "advanced"]) == false
  end

  test "a chosen voice turns it on" do
    write_state(%{"voices" => %{"nl" => "Fake Vlaams"}})
    assert Store.setting("advanced") == true
  end

  test "update checks off turns it on" do
    write_state(%{"update_check" => "never"})
    assert Store.setting("advanced") == true
  end

  test "a renamed device turns it on" do
    write_state(%{}, %{"device_name" => "Hall PC with a name of its own"})
    assert Store.setting("advanced") == true
  end

  test "a tournament with a room turns it on" do
    write_state(%{}, %{
      "tournaments" => %{
        "a" => %{"id" => "a", "announcer" => %{"name" => nil, "room" => "Annex"}}
      }
    })

    assert Store.setting("advanced") == true
  end

  test "an explicit choice is never overridden by the derivation" do
    write_state(%{"voices" => %{"nl" => "Fake Vlaams"}, "advanced" => false})
    assert Store.setting("advanced") == false
  end

  test "the derivation runs once: later changes do not flip it" do
    write_state(%{"voices" => %{"nl" => "x"}})
    assert Store.setting("advanced") == true
    Store.put_setting("advanced", false)
    Store.reload()
    assert Store.setting("advanced") == false
  end
end
