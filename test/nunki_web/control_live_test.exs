defmodule NunkiWeb.ControlLiveTest do
  @moduledoc "The control page: the list, the join field, the speech settings and the buttons."

  use Nunki.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nunki.{Announcer, Countdown, FakeServer, Speaker, Store}

  @endpoint NunkiWeb.Endpoint

  defp tournament(round \\ nil) do
    {:ok, id} =
      Store.add_tournament(%{
        "server" => "fake",
        "socket" => "ws://127.0.0.1:1/p/nunki/link",
        "key" => "k",
        "tournament" => %{"id" => "t-1", "name" => "Fake Open"}
      })

    if round,
      do:
        Store.update_tournament(
          id,
          &Map.merge(&1, %{"round" => round, "announced" => round["round"]})
        )

    id
  end

  test "an empty page says how to start, and has the join field" do
    {:ok, view, _html} = live(local_conn(), "/")
    assert has_element?(view, "#tournaments-empty")
    assert has_element?(view, "#join-form")
    assert has_element?(view, "#brand svg.logo")
    assert has_element?(view, "#hall-link[href='/hall']")
  end

  test "joining from the page puts the tournament in the list" do
    server = FakeServer.start()
    {:ok, view, _html} = live(local_conn(), "/")

    view |> form("#join-form", join: %{link: FakeServer.link(server)}) |> render_submit()

    [t] = Store.tournaments()
    assert has_element?(view, "#tournaments-#{t["id"]}")
    refute has_element?(view, "#join-error")
  end

  test "a bad link is said under the field, nothing joined" do
    {:ok, view, _html} = live(local_conn(), "/")

    view
    |> form("#join-form", join: %{link: "https://x.example/p/polis/join/AB"})
    |> render_submit()

    assert has_element?(view, "#join-error")
    assert Store.tournaments() == []
  end

  describe "name and room" do
    setup do: Store.put_setting("advanced", true)

    test "with the line down the fields are disabled, and asking is refused" do
      id = tournament()
      {:ok, view, _html} = live(local_conn(), "/")
      row = "#tournaments-#{id}"

      assert has_element?(view, "#{row}-settings input[name='announcer[name]'][disabled]")
      assert has_element?(view, "#{row}-settings input[name='announcer[room]'][disabled]")
      assert has_element?(view, "#{row}-settings-down")

      html =
        render_submit(view, "announcer_save", %{
          "announcer" => %{"tournament" => id, "name" => "x", "room" => "y"}
        })

      assert html =~ "line is down"
    end

    test "with the line up: sent on save, and shown only when the server answers" do
      server = FakeServer.start()

      FakeServer.set(server, :on_welcome, [
        %{"type" => "settings", "name" => "Hall PC", "room" => "Main hall"}
      ])

      {:ok, id} = Nunki.Tournaments.join(FakeServer.link(server))
      eventually(fn -> Nunki.Link.info(id).up? end)
      eventually(fn -> Store.tournament(id)["announcer"] end)

      {:ok, view, _html} = live(local_conn(), "/")
      row = "#tournaments-#{id}"

      refute has_element?(view, "#{row}-settings input[disabled]")
      refute has_element?(view, "#{row}-settings-down")

      assert has_element?(
               view,
               "#{row}-settings input[name='announcer[room]'][value='Main hall']"
             )

      view
      |> form("#{row}-settings", announcer: %{name: "Side PC", room: "Side hall"})
      |> render_submit()

      eventually(fn -> FakeServer.frames(server, "settings") != [] end)

      assert [%{"name" => "Side PC", "room" => "Side hall"}] =
               FakeServer.frames(server, "settings")

      assert has_element?(
               view,
               "#{row}-settings input[name='announcer[room]'][value='Main hall']"
             )

      FakeServer.push(server, %{"type" => "settings", "name" => "Side PC", "room" => "Side hall"})

      eventually(fn ->
        has_element?(view, "#{row}-settings input[name='announcer[room]'][value='Side hall']")
      end)
    end
  end

  describe "room choice" do
    setup do: Store.put_setting("advanced", true)

    defp joined_with(frame) do
      server = FakeServer.start()
      FakeServer.set(server, :on_welcome, [Map.put(frame, "type", "settings")])
      {:ok, id} = Nunki.Tournaments.join(FakeServer.link(server))
      eventually(fn -> Nunki.Link.info(id).up? end)
      eventually(fn -> Store.tournament(id)["announcer"] end)
      {server, id}
    end

    test "with rooms from the server the room is a select, 'No room' first" do
      {server, id} =
        joined_with(%{
          "name" => "Hall PC",
          "room" => "Annex",
          "rooms_available" => ["Main hall", "Annex"]
        })

      {:ok, view, _html} = live(local_conn(), "/")
      row = "#tournaments-#{id}"

      refute has_element?(view, "#{row}-settings input[name='announcer[room]']")
      assert has_element?(view, "#{row}-settings select[name='announcer[room]']")
      assert has_element?(view, "#{row}-settings select option[value='']", "No room")
      assert has_element?(view, "#{row}-settings select option[value='Main hall']")
      assert has_element?(view, "#{row}-settings select option[value='Annex'][selected]")

      view
      |> form("#{row}-settings", announcer: %{room: "Main hall"})
      |> render_submit()

      eventually(fn -> FakeServer.frames(server, "settings") != [] end)
      assert [%{"room" => "Main hall"}] = FakeServer.frames(server, "settings")
    end

    test "a free-text room from before rooms stays as an option" do
      {_server, id} =
        joined_with(%{"name" => "Hall PC", "room" => "Old foyer", "rooms_available" => ["Annex"]})

      {:ok, view, _html} = live(local_conn(), "/")

      assert has_element?(
               view,
               "#tournaments-#{id}-settings select option[value='Old foyer'][selected]"
             )
    end

    test "a refusal from the server is said on the page" do
      {server, _id} = joined_with(%{"name" => "Hall PC", "room" => "", "rooms_available" => []})
      {:ok, view, _html} = live(local_conn(), "/")

      FakeServer.push(server, %{
        "type" => "settings",
        "name" => "Hall PC",
        "room" => "",
        "rooms_available" => [],
        "error" => "room"
      })

      eventually(fn -> render(view) =~ "not one of this tournament" end)
    end
  end

  test "a joined tournament: its line, its round, Read now, a countdown, Remove" do
    id = tournament(payload(3))
    {:ok, view, _html} = live(local_conn(), "/")

    row = "#tournaments-#{id}"
    assert has_element?(view, "#{row} .dot.down")
    assert has_element?(view, "#{row}-round")

    view |> element("#{row}-read") |> render_click()
    eventually(fn -> "Pairings for round 3 are published." in Fake.texts() end)

    view
    |> form("#{row}-countdown-form", %{"tournament" => id, "minutes" => "5"})
    |> render_submit()

    assert %{round: 3, source: :local, remaining_ms: 300_000} = Countdown.get(id)
    assert has_element?(view, "#{row}-countdown")

    view |> element("#{row}-cancel") |> render_click()
    assert Countdown.get(id) == nil

    view |> element("#{row}-remove") |> render_click()
    assert Store.tournaments() == []
    assert has_element?(view, "#tournaments-empty")
  end

  test "removing with the line down says OpenPairings was not told" do
    id = tournament()
    {:ok, view, _html} = live(local_conn(), "/")
    row = "#tournaments-#{id}"

    html = view |> element("#{row}-remove") |> render_click()
    assert html =~ "was not told"
    assert Store.tournaments() == []
  end

  test "announcing from the control page: a canned button and free text" do
    id = tournament(payload(3))
    {:ok, view, _html} = live(local_conn(), "/")
    row = "#tournaments-#{id}"

    view |> element("#{row}-canned-seats") |> render_click()
    eventually(fn -> "Players, please take your seats." in Fake.texts() end)
    assert has_element?(view, "#{row}-last-announcement")

    view
    |> form("#{row}-announce-form", %{
      "announce" => %{"tournament" => id, "text" => "Tea at four."}
    })
    |> render_submit()

    eventually(fn -> "Tea at four." in Fake.texts() end)
  end

  test "Read now and the countdown need pairings first" do
    id = tournament()
    {:ok, view, _html} = live(local_conn(), "/")
    assert has_element?(view, "#tournaments-#{id}-read[disabled]")
    assert has_element?(view, "#tournaments-#{id}-countdown-start[disabled]")
  end

  test "the language override, the voice and read-on-publish are kept" do
    Store.put_setting("advanced", true)
    {:ok, view, _html} = live(local_conn(), "/")

    view
    |> form("#speech-form",
      speech: %{language: "nl", read_on_publish: "false", voice_nl: "Fake Vlaams"}
    )
    |> render_change()

    assert Store.setting("language") == "nl"
    assert Store.setting("read_on_publish") == false
    assert Store.setting("voices")["nl"] == "Fake Vlaams"
    assert Announcer.language(tournament()) == "nl"
  end

  test "Test voice speaks the test line in that language (with the fake)" do
    Store.put_setting("advanced", true)
    {:ok, view, _html} = live(local_conn(), "/")
    view |> element("#test-voice-nl") |> render_click()
    eventually(fn -> Fake.texts() == ["Zo klinkt de omroep in deze zaal."] end)
  end

  test "what is being said is on the page, and Stop stops it" do
    Fake.hold()
    {:ok, view, _html} = live(local_conn(), "/")
    Speaker.say(["Board 1: somebody against somebody else."], "en")
    eventually(fn -> has_element?(view, "#speaker-line") end)

    view |> element("#stop") |> render_click()
    refute Speaker.speaking?()
    eventually(fn -> has_element?(view, "#speaker-idle") end)
  end

  test "the update banner: install refused while busy, a second yes, later" do
    Nunki.Updates.Checker.put(%{
      version: "9.9.9",
      tag: "v9.9.9",
      url: "https://example.invalid",
      size: 10_485_760,
      asset: "a",
      no_build: false
    })

    on_exit(fn -> Nunki.Updates.Checker.forget() end)

    {:ok, view, _html} = live(local_conn(), "/")
    assert has_element?(view, "#update-banner")
    assert has_element?(view, "#update-banner-size")
    # Tests run as a copy that cannot update itself.
    assert has_element?(view, "#update-manual")
    refute has_element?(view, "#update-apply")

    view |> element("#update-later") |> render_click()
    refute has_element?(view, "#update-banner")
  end

  test "an installed copy: Install, refused while a countdown runs, then the second yes" do
    Application.put_env(:nunki, :install_kind, :velopack)
    me = self()
    Application.put_env(:nunki, :updates_stop_fun, fn code -> send(me, {:stopped, code}) end)
    Application.put_env(:nunki, :updates_stop_delay, 0)

    Nunki.Updates.Checker.put(%{
      version: "9.9.9",
      tag: "v9.9.9",
      url: "https://example.invalid",
      size: nil,
      asset: "NunkiApp-9.9.9-full.nupkg",
      no_build: false
    })

    on_exit(fn ->
      Nunki.Updates.Checker.forget()
      Application.put_env(:nunki, :install_kind, :manual)
      Application.delete_env(:nunki, :updates_stop_fun)
      Application.delete_env(:nunki, :updates_stop_delay)
    end)

    id = tournament()
    {:ok, _} = Countdown.start(id, 5, 900)

    {:ok, view, _html} = live(local_conn(), "/")
    view |> element("#update-apply") |> render_click()
    assert has_element?(view, "#update-busy")
    assert has_element?(view, "#update-force[data-confirm]")
    refute_received {:stopped, _}

    view |> element("#update-force") |> render_click()
    assert has_element?(view, "#update-going")
    assert_receive {:stopped, 90}
    Countdown.cancel(id)
  end

  test "a Linux update that failed says so, instead of 'reconnects by itself' for ever" do
    path = Path.join(System.tmp_dir!(), "nunki-status-#{System.unique_integer([:positive])}")
    dir = Path.join(System.tmp_dir!(), "nunki-req-#{System.unique_integer([:positive])}")
    old_data = Application.fetch_env!(:nunki, :data_dir)
    Application.put_env(:nunki, :data_dir, dir)
    File.mkdir_p!(Path.join(dir, "update"))
    Application.put_env(:nunki, :install_kind, :systemd)
    Application.put_env(:nunki, :update_status_file, path)
    Application.put_env(:nunki, :update_poll_ms, 10)

    Nunki.Updates.Checker.put(%{
      version: "9.9.9",
      tag: "v9.9.9",
      url: "https://example.invalid",
      size: nil,
      asset: "nunki-linux-x86_64.tar.gz",
      no_build: false
    })

    on_exit(fn ->
      Nunki.Updates.Checker.forget()
      Application.put_env(:nunki, :install_kind, :manual)
      Application.put_env(:nunki, :data_dir, old_data)
      Application.delete_env(:nunki, :update_status_file)
      Application.delete_env(:nunki, :update_poll_ms)
      File.rm(path)
      File.rm_rf(dir)
    end)

    {:ok, view, _html} = live(local_conn(), "/")
    view |> element("#update-apply") |> render_click()
    assert has_element?(view, "#update-going")

    File.write!(path, "failed 9.9.9 the download did not succeed; nothing was changed\n")

    assert eventually(fn -> has_element?(view, "#update-failed") end)
    refute has_element?(view, "#update-going")
    assert has_element?(view, "#update-apply")
  end

  test "Start with Windows is offered only to an installed Windows copy" do
    {:ok, view, _html} = live(local_conn(), "/")
    # config/test.exs: install_kind is :manual.
    refute has_element?(view, "#autostart")
  end

  test "the language switch is a form posting to /locale" do
    {:ok, view, _html} = live(local_conn(), "/")
    assert has_element?(view, "form#language[action='/locale'] button#lang-nl")

    conn = post(local_conn(), "/locale", %{"locale" => "nl", "return_to" => "/"})
    assert redirected_to(conn) == "/"
    {:ok, _view, html} = live(recycle(conn), "/")
    assert html =~ "Toernooien"
  end

  describe "advanced features" do
    @advanced ~w(#test-voice-en #test-voice-nl #refresh-voices #device-panel)

    test "off by default: the page is small, the basics stay" do
      id = tournament(payload(1))
      {:ok, view, _html} = live(local_conn(), "/")

      for sel <- @advanced, do: refute(has_element?(view, sel), sel)
      refute has_element?(view, "#speech-form select[name='speech[voice_en]']")
      refute has_element?(view, "#tournaments-#{id}-settings")

      for sel <- ~w(#speaker #stop #join-form #speech-form #advanced-toggle) do
        assert has_element?(view, sel), sel
      end

      assert has_element?(view, "#tournaments-#{id}-read")
      assert has_element?(view, "#tournaments-#{id}-countdown-form")
      assert has_element?(view, "#speech-form select[name='speech[language]']")
      assert has_element?(view, "#speech-form input[name='speech[read_on_publish]']")
      refute has_element?(view, "#advanced-toggle[checked]")
    end

    test "the switch shows and hides them, and is kept" do
      id = tournament()
      {:ok, view, _html} = live(local_conn(), "/")

      view |> element("#advanced-toggle") |> render_click()
      assert Store.setting("advanced") == true
      for sel <- @advanced, do: assert(has_element?(view, sel), sel)
      assert has_element?(view, "#tournaments-#{id}-settings")
      assert has_element?(view, "#advanced-toggle[checked]")

      view |> element("#advanced-toggle") |> render_click()
      assert Store.setting("advanced") == false
      for sel <- @advanced, do: refute(has_element?(view, sel), sel)
    end

    test "a chosen voice is still used while its picker is hidden" do
      Store.put_setting("voices", %{"nl" => "Fake Vlaams"})
      {:ok, view, _html} = live(local_conn(), "/")
      refute has_element?(view, "#speech-form select[name='speech[voice_nl]']")
      assert Store.setting("voices")["nl"] == "Fake Vlaams"
    end

    test "Dutch label" do
      conn = post(local_conn(), "/locale", %{"locale" => "nl", "return_to" => "/"})
      {:ok, _view, html} = live(recycle(conn), "/")
      assert html =~ "Geavanceerde functies tonen"
    end
  end

  describe "the hall screens" do
    test "both screens have their three buttons, the picker and the sound switch" do
      {:ok, view, _html} = live(local_conn(), "/")

      for screen <- ["hdmi1", "hdmi2"], mode <- ["live", "paused", "black"] do
        assert has_element?(view, "#screen-#{screen}-#{mode}"), "#{screen} #{mode}"
      end

      assert has_element?(view, "#screen-hdmi1-live[aria-pressed=true]")
      assert has_element?(view, "#screen-hdmi2-tournament-form")
      assert has_element?(view, "#screen-hdmi2-open[href='/hall?screen=hdmi2']")
      assert has_element?(view, "#audio-toggle[aria-checked=true]")
      refute has_element?(view, "#audio-off")
    end

    test "a mode button sets that screen's mode" do
      {:ok, view, _html} = live(local_conn(), "/")
      view |> element("#screen-hdmi2-black") |> render_click()

      assert Nunki.Hall.screen("hdmi2")["mode"] == "black"
      assert Nunki.Hall.screen("hdmi1")["mode"] == "live"
      assert has_element?(view, "#screen-hdmi2-black[aria-pressed=true]")
      assert has_element?(view, "#screen-hdmi2.mode-black")
    end

    test "the picker chooses what a screen shows; Automatic gives it back" do
      id = tournament(payload(2))
      {:ok, view, _html} = live(local_conn(), "/")

      view
      |> form("#screen-hdmi1-tournament-form", %{"screen" => "hdmi1", "id" => id})
      |> render_change()

      assert Nunki.Hall.screen("hdmi1")["tournament"] == id

      view
      |> form("#screen-hdmi1-tournament-form", %{"screen" => "hdmi1", "id" => ""})
      |> render_change()

      assert Nunki.Hall.screen("hdmi1")["tournament"] == nil
    end

    test "the sound switch: off says so plainly, and nothing is said" do
      {:ok, view, _html} = live(local_conn(), "/")
      view |> element("#audio-toggle") |> render_click()

      refute Nunki.Hall.audio?()
      assert has_element?(view, "#audio-toggle[aria-checked=false]")
      assert has_element?(view, "#audio-off")

      Speaker.say(["nobody hears this"], "en")
      _ = :sys.get_state(Speaker)
      assert Fake.texts() == []
    end

    test "a change made elsewhere (the local API) is on the page at once" do
      {:ok, view, _html} = live(local_conn(), "/")
      Nunki.Hall.put_mode("hdmi1", "paused")
      eventually(fn -> has_element?(view, "#screen-hdmi1-paused[aria-pressed=true]") end)
      Nunki.Hall.put_audio(false)
      eventually(fn -> has_element?(view, "#audio-off") end)
    end

    test "Identify asks every hall screen to show its number" do
      Nunki.subscribe()
      {:ok, view, _html} = live(local_conn(), "/")
      view |> element("#identify") |> render_click()
      assert_receive {:identify, _ms}
    end
  end
end
