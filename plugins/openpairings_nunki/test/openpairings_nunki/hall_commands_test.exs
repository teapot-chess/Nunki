defmodule OpenPairingsNunki.HallCommandsTest do
  @moduledoc """
  What Manubrium's hall page and the tournament page ask of the announcers:
  `hall_status/2`, `hall_command/3`, `Hall.announce/4` and the longer
  countdowns, each answered the way the `manubrium-v1` contract says.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import OpenPairingsNunki.Fixtures
  import Phoenix.LiveViewTest

  alias OpenPairingsNunki.{Contract, Hall, Plugin}
  alias PairingsEngine.{Features, Plugins}
  alias PairingsEngine.Accounts.Scope

  setup :register_and_log_in_user
  setup :setup_admin

  setup %{scope: scope} do
    t = tournament!(scope)
    Hall.subscribe(t.id)
    %{t: t}
  end

  describe "hall_status/2" do
    test "lists the announcers, online or not, and no countdown", %{scope: scope, t: t} do
      {a, _key} = announcer!(scope, t)

      assert %{app: "nunki", countdown: nil, devices: [device]} = Plugin.hall_status(scope, t)
      assert %{id: id, online: false, last_seen_at: _, room: _, name: _} = device
      assert id == a.id
    end

    test "carries the countdown that runs", %{scope: scope, t: t} do
      publish!(t, 1)
      {:ok, _} = Hall.start_countdown(scope, t, 10)

      assert %{countdown: %{round: 1, seconds_left: left}} = Plugin.hall_status(scope, t)
      assert left in 595..600
    end

    test "is nil with the feature off for the owner", %{user: user, t: t} do
      {:ok, user} = Features.set_enabled(user, [])
      assert Plugin.hall_status(Scope.for_user(user), t) == nil
    end

    test "is in the core's list of hall apps", %{scope: scope, t: t} do
      assert [%{app: "nunki"}] = Plugins.hall_status(scope, t)
    end
  end

  describe "hall_command/3" do
    test "announce: canned or text, one frame, to the announcers online", %{scope: scope, t: t} do
      assert {:ok, 0} = Plugin.hall_command(scope, t, {:announce, "silence", nil})
      assert_receive {:nunki_send, %{type: "announce", canned: "silence", id: id} = frame}
      Contract.assert_valid!("server-announce", stringify(frame))
      assert id =~ ~r/\A[0-9a-f]{16}\z/

      assert {:ok, 0} = Plugin.hall_command(scope, t, {:announce, nil, "  Tea at four.  "})
      assert_receive {:nunki_send, %{type: "announce", text: "Tea at four."} = frame}
      refute Map.has_key?(frame, :canned)
      Contract.assert_valid!("server-announce", stringify(frame))
    end

    test "announce: an unknown phrase is dropped, nothing at all is refused", %{
      scope: scope,
      t: t
    } do
      assert {:ok, _} = Plugin.hall_command(scope, t, {:announce, "yodel", "Hello."})
      assert_receive {:nunki_send, %{text: "Hello."} = frame}
      refute Map.has_key?(frame, :canned)

      assert {:error, :empty} = Plugin.hall_command(scope, t, {:announce, "yodel", "   "})
      refute_receive {:nunki_send, _}
    end

    test "announce: text is cut at 300 characters", %{scope: scope, t: t} do
      Plugin.hall_command(scope, t, {:announce, nil, String.duplicate("a", 500)})
      assert_receive {:nunki_send, %{text: text}}
      assert String.length(text) == 300
    end

    test "countdown: needs a published round; 20 and 30 minutes are allowed", %{
      scope: scope,
      t: t
    } do
      assert {:error, :no_round} = Plugin.hall_command(scope, t, {:countdown, 5})
      publish!(t, 1)

      for minutes <- [20, 30] do
        assert {:ok, 0} = Plugin.hall_command(scope, t, {:countdown, minutes})
        assert_receive {:nunki_send, %{type: "countdown", seconds_left: s}}
        assert s in (minutes * 60 - 5)..(minutes * 60)
      end

      assert {:error, :minutes} = Plugin.hall_command(scope, t, {:countdown, 7})
    end

    test "cancel: ends the one that runs; none running is not an error", %{scope: scope, t: t} do
      assert {:ok, 0} = Plugin.hall_command(scope, t, :cancel_countdown)
      publish!(t, 1)
      {:ok, _} = Hall.start_countdown(scope, t, 5)
      assert {:ok, 0} = Plugin.hall_command(scope, t, :cancel_countdown)
      assert Hall.current_countdown(t.id) == nil
    end

    test "print is not Nunki's job; with the feature off nothing is", %{
      scope: scope,
      user: user,
      t: t
    } do
      assert Plugin.hall_command(scope, t, {:print, "both"}) == :unsupported

      {:ok, user} = Features.set_enabled(user, [])

      assert Plugin.hall_command(Scope.for_user(user), t, {:announce, "silence", nil}) ==
               :unsupported
    end

    test "the core adds the announcers up", %{scope: scope, t: t} do
      assert {:ok, 0} = Plugins.hall_command(scope, t, {:announce, "seats", nil})
      assert {:error, :no_hall} = Plugins.hall_command(scope, t, {:print, "both"})
    end
  end

  describe "the tournament page" do
    test "canned buttons and free text reach the announcers", %{conn: conn, t: t} do
      {:ok, view, _html} = live(conn, "/p/nunki/tournaments/#{t.id}")

      view |> element("#nunki-canned-phones") |> render_click()
      assert_receive {:nunki_send, %{type: "announce", canned: "phones"}}

      view |> form("#nunki-announce-form", announce: %{text: "Coffee."}) |> render_submit()
      assert_receive {:nunki_send, %{type: "announce", text: "Coffee."}}

      view |> form("#nunki-announce-form", announce: %{text: "  "}) |> render_submit()
      refute_receive {:nunki_send, _}
    end
  end

  defp stringify(frame), do: frame |> Jason.encode!() |> Jason.decode!()
end
