defmodule Nunki.HallTest do
  @moduledoc "`Nunki.Hall`: the screens' modes and tournaments, and the sound, kept across a restart."

  use Nunki.Case, async: false

  alias Nunki.{Hall, Speaker, Store}

  defp tournament(name) do
    {:ok, id} =
      Store.add_tournament(%{
        "server" => "fake",
        "socket" => "ws://127.0.0.1:1/p/nunki/link/#{name}",
        "key" => "k",
        "tournament" => %{"id" => name, "name" => name}
      })

    id
  end

  test "both screens start live and automatic" do
    assert Hall.all() == %{
             "hdmi1" => %{"mode" => "live", "tournament" => nil},
             "hdmi2" => %{"mode" => "live", "tournament" => nil}
           }
  end

  test "a mode is kept per screen, survives a restart, and is broadcast" do
    Nunki.subscribe()
    assert :ok = Hall.put_mode("hdmi2", "black")
    assert_receive {:hall_screen, "hdmi2", %{"mode" => "black"}}

    Store.reload()
    assert Hall.screen("hdmi2")["mode"] == "black"
    assert Hall.screen("hdmi1")["mode"] == "live"
  end

  test "an unknown screen or mode is refused" do
    assert {:error, :screen} = Hall.put_mode("hdmi3", "live")
    assert {:error, :mode} = Hall.put_mode("hdmi1", "dim")
    assert Hall.screen_name("hdmi9") == "hdmi1"
    assert Hall.screen_name(nil) == "hdmi1"
  end

  test "a screen's tournament must be joined; removing it puts the screen back on automatic" do
    id = tournament("Open A")
    assert {:error, :tournament} = Hall.put_tournament("hdmi1", "nope")
    assert :ok = Hall.put_tournament("hdmi1", id)
    assert Hall.screen("hdmi1")["tournament"] == id

    Nunki.Tournaments.remove(id)
    assert Hall.screen("hdmi1")["tournament"] == nil
  end

  test "pick: ?t= first, then the screen's choice, then automatic" do
    a = tournament("Open A")
    b = tournament("Open B")
    ts = Store.tournaments()
    first = hd(ts)["id"]
    other = if first == a, do: b, else: a
    assert Hall.pick(ts, %{}, nil, nil)["id"] == first
    assert Hall.pick(ts, %{}, nil, other)["id"] == other
    assert Hall.pick(ts, %{}, first, other)["id"] == first
    assert Hall.pick(ts, %{}, nil, "gone")["id"] == first
  end

  describe "sound" do
    test "on by default; NUNKI_AUDIO=off makes the default off, and a choice beats it" do
      assert Hall.audio?()

      Application.put_env(:nunki, :audio_default, false)
      on_exit(fn -> Application.delete_env(:nunki, :audio_default) end)
      refute Hall.audio?()

      Hall.put_audio(true)
      assert Hall.audio?()
      Store.reload()
      assert Hall.audio?()
    end

    test "off: nothing is said, nothing is queued for later, and what was being said stops" do
      Fake.hold()
      Speaker.say(["first"], "en")
      eventually(fn -> Speaker.speaking?() end)

      Hall.put_audio(false)
      refute Speaker.speaking?()

      Speaker.say(["second"], "en")
      _ = :sys.get_state(Speaker)
      assert Speaker.status().queued == 0
      refute Speaker.speaking?()

      Hall.put_audio(true)
      _ = :sys.get_state(Speaker)
      assert Fake.texts() == ["first"]
    end
  end
end
