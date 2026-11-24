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
    fresh = %{"mode" => "live", "tournament" => nil, "source" => "hall", "url" => nil}
    assert Hall.all() == %{"hdmi1" => fresh, "hdmi2" => fresh}
  end

  describe "a web page instead of the broadcast" do
    test "kept per screen, survives a restart, is broadcast, and the address outlives a switch back" do
      Nunki.subscribe()
      assert :ok = Hall.put_source("hdmi2", "web", " https://openresults.cloud/t/x/live/1/all ")
      assert_receive {:hall_screen, "hdmi2", %{"source" => "web", "url" => url}}
      assert url == "https://openresults.cloud/t/x/live/1/all"

      Store.reload()
      assert Hall.screen("hdmi2")["source"] == "web"
      assert Hall.screen("hdmi1")["source"] == "hall"

      assert :ok = Hall.put_source("hdmi2", "hall")
      assert Hall.screen("hdmi2")["source"] == "hall"
      assert Hall.screen("hdmi2")["url"] == url

      # "web" without an address uses the one it has.
      assert :ok = Hall.put_source("hdmi2", "web")
      assert Hall.screen("hdmi2")["source"] == "web"
    end

    test "web without any address, an unknown screen or source are refused" do
      assert {:error, :no_url} = Hall.put_source("hdmi1", "web")
      assert {:error, :no_url} = Hall.put_source("hdmi1", "web", "   ")
      assert {:error, :screen} = Hall.put_source("hdmi3", "hall")
      assert {:error, :source} = Hall.put_source("hdmi1", "video")
      assert {:error, {:url, :insecure}} = Hall.put_source("hdmi1", "web", "http://example.org")
    end

    test "which addresses are accepted" do
      ok = [
        "https://openresults.cloud/t/club/projector",
        "HTTPS://Example.org",
        "https://192.168.1.5:8080/x",
        "https://8.8.8.8/",
        "http://localhost:4000/",
        "http://127.0.0.1/",
        "http://10.1.2.3/",
        "http://172.16.0.1/",
        "http://172.31.255.254/",
        "http://192.168.0.10/live",
        "http://[::1]/",
        "http://hall-pi.local/board",
        "http://Hall.LOCAL:8080"
      ]

      for url <- ok, do: assert({:ok, _} = Hall.check_url(url), url)

      bad = [
        {"", :empty},
        {"   ", :empty},
        {"openresults.cloud/t/x", :invalid},
        {"https://", :invalid},
        {"https://exa mple.org", :invalid},
        {"ftp://example.org/f", :scheme},
        {"javascript:alert(1)", :invalid},
        {"file:///etc/passwd", :invalid},
        {"//example.org", :scheme},
        {"https://user:pw@example.org/", :credentials},
        {"http://example.org/", :insecure},
        {"http://8.8.8.8/", :insecure},
        {"http://172.32.0.1/", :insecure},
        {"http://172.15.0.1/", :insecure},
        {"http://192.169.0.1/", :insecure},
        {"http://11.0.0.1/", :insecure},
        {"http://localhost.example.org/", :insecure},
        {"http://notlocal/", :insecure},
        {"http://example.local.evil.org/", :insecure},
        {"https://" <> String.duplicate("a", 2_100) <> ".org", :too_long}
      ]

      for {url, why} <- bad, do: assert({:error, ^why} = Hall.check_url(url), url)
    end

    test "an address edited into state.json by hand that would be refused is ignored" do
      Store.put_setting("screens", %{
        "hdmi1" => %{"source" => "web", "url" => "http://example.org/"}
      })

      assert Hall.screen("hdmi1")["source"] == "hall"
      assert Hall.screen("hdmi1")["url"] == nil
    end
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
