defmodule OpenPairingsNunkiWeb.LinkSocketTest do
  @moduledoc """
  The announcer's link, its `WebSock` callbacks driven directly with the
  test process standing in for the socket process: hello and its answers,
  the round on welcome and on publication (once), the countdown restated,
  the page's commands, and removal.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import OpenPairingsNunki.Fixtures

  alias OpenPairingsNunki.{Announcer, Countdown, Hall}
  alias OpenPairingsNunkiWeb.LinkSocket
  alias PairingsEngine.Repo

  setup :register_and_log_in_user
  setup :setup_admin

  setup %{scope: scope} do
    t = tournament!(scope)
    {a, key} = announcer!(scope, t)
    %{t: t, announcer: a, key: key}
  end

  defp hello(device, key, v \\ 1) do
    frame =
      Jason.encode!(%{
        type: "hello",
        v: v,
        device: device,
        key: key,
        name: "Hall PC",
        software: "nunki 0.1.0"
      })

    LinkSocket.handle_in({frame, opcode: :text}, LinkSocket.new_state())
  end

  defp frames({:push, frames, _state}), do: frames |> List.wrap() |> Enum.map(&decode/1)
  defp frames({:stop, :normal, _code, frames, _state}), do: Enum.map(frames, &decode/1)

  defp decode({:text, json}), do: Jason.decode!(json)

  defp state({:push, _frames, state}), do: state
  defp state({:ok, state}), do: state

  defp welcomed(%{announcer: a, key: key}) do
    result = hello(a.device_id, key)
    assert {:push, _, _} = result
    result
  end

  describe "hello" do
    test "with a good key: welcome, and the announcer is online", %{t: t} = ctx do
      result = welcomed(ctx)
      assert [%{"type" => "welcome", "v" => 1, "tournament" => tour} | _] = frames(result)
      assert tour == %{"id" => t.id, "name" => t.name, "results" => nil}

      a = Repo.get!(Announcer, ctx.announcer.id)
      assert a.connected
      assert Hall.online?(a)
    end

    test "with a wrong key: refused key", %{announcer: a} do
      result = hello(a.device_id, "not-the-key")
      assert [%{"type" => "refused", "reason" => "key"}] = frames(result)
    end

    test "with another device's id: refused key", %{key: key} do
      assert [%{"reason" => "key"}] = frames(hello("someone-else", key))
    end

    test "after removal: refused revoked", %{scope: scope, t: t, announcer: a, key: key} do
      :ok = Hall.revoke(scope, t, a.id)
      assert [%{"type" => "refused", "reason" => "revoked"}] = frames(hello(a.device_id, key))
    end

    test "after the account switched the feature off: refused revoked", %{
      announcer: a,
      key: key,
      user: user
    } do
      {:ok, _} = PairingsEngine.Features.set_enabled(user, [])
      assert [%{"type" => "refused", "reason" => "revoked"}] = frames(hello(a.device_id, key))
    end

    test "in another protocol version: refused version", %{announcer: a, key: key} do
      assert [%{"reason" => "version"}] = frames(hello(a.device_id, key, 2))
    end

    test "nothing but hello is listened to before hello" do
      status = Jason.encode!(%{type: "status", voice: "x"})

      assert {:ok, %{announcer: nil}} =
               LinkSocket.handle_in({status, opcode: :text}, LinkSocket.new_state())
    end
  end

  describe "the results address" do
    setup %{t: t} do
      PairingsEngine.Publishing.put_public_base("https://openresults.example")
      on_exit(fn -> PairingsEngine.Publishing.put_public_base(nil) end)
      %{t: t}
    end

    defp make_public!(t) do
      t
      |> Ecto.Changeset.change(publish_to_openresults: true, public_slug: "open-somewhere")
      |> Repo.update!()
    end

    test "is null in welcome and round while the tournament is not public", %{t: t} = ctx do
      publish!(t, 1)

      assert [%{"tournament" => %{"results" => nil}}, _settings, %{"type" => "round"} = round] =
               frames(welcomed(ctx))

      assert Map.fetch!(round, "results") == nil
    end

    test "is the front page in welcome and round once it is public", %{t: t} = ctx do
      publish!(t, 1)
      make_public!(t)

      assert [%{"tournament" => %{"results" => results}}, _settings, round] =
               frames(welcomed(ctx))

      assert results == "https://openresults.example/t/open-somewhere"
      assert round["results"] == results
    end

    test "a change of address alone sends the round again, once", %{t: t} = ctx do
      publish!(t, 1)
      state = ctx |> welcomed() |> state()
      make_public!(t)

      result = LinkSocket.handle_info(:recheck, %{state | recheck: nil})

      assert [%{"type" => "round", "results" => "https://openresults.example/t/open-somewhere"}] =
               frames(result)

      assert {:ok, _} = LinkSocket.handle_info(:recheck, state(result))
    end
  end

  describe "the round" do
    test "is not sent while round 1 is unpublished", ctx do
      assert [%{"type" => "welcome"}, %{"type" => "settings"}] = frames(welcomed(ctx))
    end

    test "is sent on welcome once published", %{t: t} = ctx do
      publish!(t, 1)

      assert [
               %{"type" => "welcome"},
               %{"type" => "settings"},
               %{"type" => "round", "round" => payload}
             ] =
               frames(welcomed(ctx))

      assert payload["round"] == 1
      assert is_binary(payload["rev"])
    end

    test "a newly published round is sent once, and not again for the same rev", %{t: t} = ctx do
      state = ctx |> welcomed() |> state()
      tid = t.id

      publish!(t, 1)
      assert_receive {:tournament_changed, ^tid, _} = changed

      # Debounced: the nudge only arms a recheck.
      assert {:ok, %{recheck: ref} = state} = LinkSocket.handle_info(changed, state)
      assert is_reference(ref)
      # A second nudge in the same burst arms nothing new.
      assert {:ok, %{recheck: ^ref}} = LinkSocket.handle_info(changed, state)

      result = LinkSocket.handle_info(:recheck, state)
      assert [%{"type" => "round", "round" => %{"round" => 1}}] = frames(result)

      # Nothing changed: nothing sent.
      assert {:ok, state} = LinkSocket.handle_info(:recheck, state(result))
      assert state.last_round == 1
    end

    test "a round taken back is not sent", %{t: t} = ctx do
      publish!(t, 1)
      state = ctx |> welcomed() |> state()
      round = PairingsEngine.Tournaments.get_round(t.id, 1)
      {:ok, _} = PairingsEngine.Tournaments.unpublish_round(round)
      assert {:ok, _} = LinkSocket.handle_info(:recheck, state)
    end
  end

  describe "the countdown" do
    test "is restated after welcome with what is left of it", %{scope: scope, t: t} = ctx do
      publish!(t, 1)
      {:ok, cd} = Hall.start_countdown(scope, t, 5)

      assert [_welcome, _settings, _round, %{"type" => "countdown"} = c] = frames(welcomed(ctx))
      assert c["round"] == 1
      assert c["id"] == cd.token
      assert c["seconds_left"] in 290..300
    end

    test "is not restated once it has run out", %{scope: scope, t: t} = ctx do
      publish!(t, 1)
      {:ok, _} = Hall.start_countdown(scope, t, 1)

      Repo.update_all(from(c in Countdown, where: c.tournament_id == ^t.id),
        set: [ends_at: DateTime.add(DateTime.utc_now(:second), -5)]
      )

      assert [%{"type" => "welcome"}, %{"type" => "settings"}, %{"type" => "round"}] =
               frames(welcomed(ctx))
    end
  end

  describe "name and room (settings)" do
    defp settings_in(state, frame) do
      text = Jason.encode!(Map.put(frame, :type, "settings"))
      LinkSocket.handle_in({text, opcode: :text}, state)
    end

    defp row(a), do: Repo.get!(Announcer, a.id)

    # Two rooms on the tournament: boards 1 and 2 in the first, 3 in the second.
    defp rooms!(t) do
      {:ok, t} =
        PairingsEngine.Tournaments.update_tournament(t, %{
          "rooms" => [
            %{"name" => "Main hall", "boards" => "1-2"},
            %{"name" => "Annex", "boards" => "3"}
          ]
        })

      {t, PairingsEngine.Rooms.list(t)}
    end

    test "come right after welcome, as the row has them", %{announcer: a} = ctx do
      assert [%{"type" => "welcome"}, settings] = frames(welcomed(ctx))

      assert settings == %{
               "type" => "settings",
               "name" => "Hall PC",
               "room" => "",
               "rooms_available" => []
             }

      assert row(a).room == ""
    end

    test "list the tournament's rooms", %{t: t} = ctx do
      rooms!(t)
      assert [_welcome, settings] = frames(welcomed(ctx))
      assert settings["rooms_available"] == ["Main hall", "Annex"]
    end

    test "the device's name request is stored, trimmed and cut, and echoed once",
         %{announcer: a} = ctx do
      state = ctx |> welcomed() |> state()
      id = a.id

      assert {:ok, state} = settings_in(state, %{name: "  Door PC  "})
      assert %{name: "Door PC"} = row(a)
      assert_receive {:nunki_settings_changed, ^id} = changed

      result = LinkSocket.handle_info(changed, state)
      assert [%{"type" => "settings", "name" => "Door PC", "room" => ""}] = frames(result)

      # The same news again is not told twice.
      assert {:ok, _state} = LinkSocket.handle_info(changed, state(result))

      long = String.duplicate("x", 90)
      assert {:ok, _state} = settings_in(state(result), %{name: long})
      assert String.length(row(a).name) == 60
    end

    test "a room by name is set (any case, trimmed) with its id, and cleared by empty",
         %{t: t, announcer: a} = ctx do
      {_t, [main, _annex]} = rooms!(t)
      state = ctx |> welcomed() |> state()

      assert {:ok, state} = settings_in(state, %{room: "  main HALL "})
      assert %{room: "Main hall", room_id: id} = row(a)
      assert id == main.id

      {:ok, state} = settings_in(state, %{name: "Lobby PC"})
      assert %{name: "Lobby PC", room_id: ^id} = row(a)

      {:ok, state} = settings_in(state, %{name: "   ", room: ""})
      assert %{name: "Lobby PC", room: "", room_id: ""} = row(a)

      # Absent key: untouched; and a name that is no room is refused.
      {:ok, _state} = settings_in(state, %{room: "Annex"})
      assert %{room: "Annex"} = row(a)
    end

    test "a room that is none of the tournament's is refused, with the current settings",
         %{t: t, announcer: a} = ctx do
      rooms!(t)
      state = ctx |> welcomed() |> state()

      result = settings_in(state, %{name: "Door PC", room: "Foyer"})

      assert [
               %{
                 "type" => "settings",
                 "name" => "Hall PC",
                 "room" => "",
                 "rooms_available" => ["Main hall", "Annex"],
                 "error" => "room"
               }
             ] = frames(result)

      # Nothing was stored, not even the name that came along.
      assert %{name: "Hall PC", room: "", room_id: ""} = row(a)
    end

    test "a refusal with no rooms at all is the same", %{announcer: a} = ctx do
      state = ctx |> welcomed() |> state()
      result = settings_in(state, %{room: "Anywhere"})
      assert [%{"error" => "room", "rooms_available" => []}] = frames(result)
      assert row(a).room == ""
    end

    test "legacy free text is a label: kept, told, accepted back, never a room",
         %{t: t, announcer: a} = ctx do
      Repo.update_all(from(x in Announcer, where: x.id == ^a.id), set: [room: "Old foyer"])
      state = ctx |> welcomed() |> state()
      assert %{room: "Old foyer", room_id: ""} = row(a)

      # Told as it is, even with rooms in the tournament.
      rooms!(t)
      result = LinkSocket.handle_info(:recheck, %{state | recheck: nil})
      assert [%{"type" => "settings", "room" => "Old foyer"}] = frames(result)

      # The device echoes it back: unchanged, not refused.
      assert {:ok, state} = settings_in(state(result), %{name: "Hall PC", room: "Old foyer"})
      assert %{room: "Old foyer", room_id: ""} = row(a)

      # Another text is refused.
      assert [%{"error" => "room"}] = frames(settings_in(state, %{room: "Older foyer"}))
    end

    test "a rename of the room follows, and a deleted room is no room",
         %{t: t, announcer: a} = ctx do
      {t, [main, annex]} = rooms!(t)
      state = ctx |> welcomed() |> state()
      {:ok, state} = settings_in(state, %{room: "Main hall"})
      id = a.id
      assert_receive {:nunki_settings_changed, ^id}

      renamed = [
        %{"id" => main.id, "name" => "Great hall", "boards" => "1-2"},
        %{"id" => annex.id, "name" => "Annex", "boards" => "3"}
      ]

      {:ok, t} = PairingsEngine.Tournaments.update_tournament(t, %{"rooms" => renamed})
      result = LinkSocket.handle_info(:recheck, %{state | recheck: nil})
      assert [%{"type" => "settings", "room" => "Great hall"}] = frames(result)

      {:ok, _t} =
        PairingsEngine.Tournaments.update_tournament(t, %{"rooms" => [List.last(renamed)]})

      result = LinkSocket.handle_info(:recheck, %{state(result) | recheck: nil})
      assert [%{"type" => "settings", "room" => ""}] = frames(result)
    end

    test "are ignored before hello", %{announcer: a} do
      assert {:ok, %{announcer: nil}} =
               settings_in(LinkSocket.new_state(), %{name: "Intruder", room: "Anywhere"})

      assert %{name: "Hall PC", room: ""} = row(a)
    end

    test "a room picked on the page reaches the socket",
         %{scope: scope, t: t, announcer: a} =
           ctx do
      {_t, [_main, annex]} = rooms!(t)
      state = ctx |> welcomed() |> state()
      id = a.id

      assert {:ok, %{id: ^id}} =
               Hall.update_settings(scope, t, a.id, %{"name" => "Desk PC", "room_id" => annex.id})

      assert_receive {:nunki_settings_changed, ^id} = changed
      result = LinkSocket.handle_info(changed, state)
      assert [%{"type" => "settings", "name" => "Desk PC", "room" => "Annex"}] = frames(result)

      assert {:error, :room} = Hall.update_settings(scope, t, a.id, %{"room_id" => "nope"})
    end

    test "only this tournament's announcers can be changed from its page", %{scope: scope, t: t} do
      other = tournament!(scope, %{"name" => "Another Open"})
      {b, _key} = announcer!(scope, other, "device-2")

      assert {:error, :not_found} = Hall.update_settings(scope, t, b.id, %{"name" => "Hijack"})
      assert row(b).name == "Hall PC"
    end

    test "a removed announcer cannot be changed", %{scope: scope, t: t, announcer: a} do
      :ok = Hall.revoke(scope, t, a.id)
      assert {:error, :not_found} = Hall.update_settings(scope, t, a.id, %{"name" => "Ghost"})
    end
  end

  describe "the round, by room" do
    defp board_labels(result) do
      [%{"round" => payload}] = Enum.filter(frames(result), &(&1["type"] == "round"))
      {payload, Enum.map(payload["boards"], & &1["board"])}
    end

    setup %{t: t} do
      publish!(t, 1)

      {:ok, t} =
        PairingsEngine.Tournaments.update_tournament(t, %{
          "rooms" => [
            %{"name" => "Main hall", "boards" => "1"},
            %{"name" => "Annex", "boards" => "2"},
            %{"name" => "Empty", "boards" => ""}
          ]
        })

      %{t: t, rooms: PairingsEngine.Rooms.list(t)}
    end

    test "no room: every board, and no room key", ctx do
      {payload, labels} = board_labels(welcomed(ctx))
      assert length(labels) >= 3
      refute Map.has_key?(payload, "room")
    end

    test "a room gets only its boards and says which room",
         %{announcer: a, rooms: [main | _]} =
           ctx do
      Repo.update_all(from(x in Announcer, where: x.id == ^a.id),
        set: [room: main.name, room_id: main.id]
      )

      {payload, labels} = board_labels(welcomed(ctx))
      assert labels == ["1"]
      assert payload["room"] == "Main hall"
    end

    test "a room holding no boards gets none", %{announcer: a, rooms: [_, _, empty]} = ctx do
      Repo.update_all(from(x in Announcer, where: x.id == ^a.id),
        set: [room: empty.name, room_id: empty.id]
      )

      {payload, labels} = board_labels(welcomed(ctx))
      assert labels == []
      assert payload["room"] == "Empty"
    end

    test "a room change re-sends the round with a new rev", %{announcer: a} = ctx do
      state = ctx |> welcomed() |> state()
      %{last_rev: before} = state
      id = a.id

      {:ok, state} = settings_in(state, %{room: "Annex"})
      assert_receive {:nunki_settings_changed, ^id} = changed

      result = LinkSocket.handle_info(changed, state)
      assert [%{"type" => "settings"}, %{"type" => "round"}] = frames(result)
      {payload, labels} = board_labels(result)
      assert labels == ["2"]
      assert payload["rev"] != before

      # And back to no room: every board again.
      {:ok, state} = settings_in(state(result), %{room: ""})
      result = LinkSocket.handle_info({:nunki_settings_changed, id}, state)
      {payload, labels} = board_labels(result)
      assert length(labels) >= 3
      refute Map.has_key?(payload, "room")
    end

    test "a deleted room means every board again",
         %{t: t, announcer: a, rooms: [main | _]} =
           ctx do
      Repo.update_all(from(x in Announcer, where: x.id == ^a.id),
        set: [room: main.name, room_id: main.id]
      )

      state = ctx |> welcomed() |> state()
      {:ok, _t} = PairingsEngine.Tournaments.update_tournament(t, %{"rooms" => []})

      result = LinkSocket.handle_info(:recheck, %{state | recheck: nil})
      {payload, labels} = board_labels(result)
      assert length(labels) >= 3
      refute Map.has_key?(payload, "room")
    end
  end

  describe "the page's commands" do
    setup %{t: t} = ctx do
      publish!(t, 1)
      %{state: ctx |> welcomed() |> state()}
    end

    defp pass_on(state) do
      assert_receive {:nunki_send, _frame} = msg
      [frame] = frames(LinkSocket.handle_info(msg, state))
      frame
    end

    test "each reaches the socket", %{scope: scope, t: t, state: state} do
      {:ok, cd} = Hall.start_countdown(scope, t, 2)

      assert %{"type" => "countdown", "round" => 1, "seconds_left" => 120, "id" => id} =
               pass_on(state)

      assert id == cd.token

      :ok = Hall.cancel_countdown(scope, t)
      assert %{"type" => "countdown_cancel", "id" => ^id} = pass_on(state)

      {:ok, 1} = Hall.read_aloud(scope, t)
      assert %{"type" => "read", "round" => 1} = pass_on(state)

      :ok = Hall.stop_reading(scope, t)
      assert %{"type" => "stop"} = pass_on(state)
    end

    test "a removed announcer is told leave", %{scope: scope, t: t, announcer: a, state: state} do
      :ok = Hall.revoke(scope, t, a.id)
      id = a.id
      assert_receive {:nunki_revoked, ^id} = msg

      result = LinkSocket.handle_info(msg, state)
      assert [%{"type" => "leave"}] = frames(result)
      assert {:stop, :normal, _, _, %{announcer: nil}} = result
    end

    test "status is kept, leave forgets, terminate marks offline", %{announcer: a, state: state} do
      status = Jason.encode!(%{type: "status", voice: "Ellen", speaking: true})
      assert {:ok, state} = LinkSocket.handle_in({status, opcode: :text}, state)
      assert Repo.get!(Announcer, a.id).status == %{"voice" => "Ellen", "speaking" => true}

      :ok = LinkSocket.terminate(:remote, state)
      refute Repo.get!(Announcer, a.id).connected

      leave = Jason.encode!(%{type: "leave"})
      assert {:stop, :normal, _} = LinkSocket.handle_in({leave, opcode: :text}, state)
      assert Repo.get(Announcer, a.id) == nil
    end
  end

  test "a plain GET of the link is not upgraded" do
    assert build_conn() |> get("/p/nunki/link") |> Map.get(:status) == 426
  end
end
