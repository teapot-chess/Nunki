defmodule OpenPairingsNunkiWeb.ContractTest do
  @moduledoc """
  The server half of `hall-link-v1` (vendored in the Nunki repository) as
  this plugin really speaks it: every answer of `POST /p/nunki/join/:code`,
  every frame `LinkSocket` sends, checked against its schema; every frame
  the contract has a device send is taken; and the pairing code and link
  are the unified ones.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import OpenPairingsNunki.Fixtures

  alias OpenPairingsNunki.{Contract, Hall}
  alias OpenPairingsNunkiWeb.LinkSocket
  alias PairingsEngine.RateLimit

  setup :register_and_log_in_user
  setup :setup_admin

  setup %{scope: scope} do
    RateLimit.clear(:board_link_auth, "nunki_join:127.0.0.1")
    on_exit(fn -> RateLimit.clear(:board_link_auth, "nunki_join:127.0.0.1") end)
    %{t: tournament!(scope)}
  end

  defp post_join(code, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/p/nunki/join/#{code}", Jason.encode!(body))
  end

  defp frames({:push, frames, _state}), do: frames |> List.wrap() |> Enum.map(&decode/1)
  defp frames({:stop, :normal, _code, frames, _state}), do: Enum.map(frames, &decode/1)
  defp frames({:ok, _state}), do: []
  defp decode({:text, json}), do: Jason.decode!(json)

  defp state({:push, _frames, state}), do: state
  defp state({:ok, state}), do: state

  defp text_in(state, frame),
    do: LinkSocket.handle_in({Jason.encode!(frame), opcode: :text}, state)

  # Every frame out, by type, against the schema for an announcer.
  defp assert_frames!(result) do
    for frame <- frames(result) do
      schema =
        case frame["type"] do
          "settings" -> "server-settings-nunki"
          "countdown_cancel" -> "server-countdown-cancel"
          type -> "server-" <> type
        end

      Contract.assert_valid!(schema, frame)
    end

    result
  end

  defp welcomed(scope, t) do
    {a, key} = announcer!(scope, t)
    hello = %{Contract.example("device-hello") | "device" => a.device_id, "key" => key}
    result = text_in(LinkSocket.new_state(), hello) |> assert_frames!()
    assert [%{"type" => "welcome"} | _] = frames(result)
    {a, state(result)}
  end

  describe "pairing" do
    test "a new code is the unified one, in the link the contract shows", %{scope: scope, t: t} do
      {:ok, %{code: code, url: url, expires_at: expires_at}} = Hall.create_join_code(scope, t)

      Contract.assert_valid!("pairing-link", %{
        "app" => "nunki",
        "link" => url,
        "server" => PairingsEngineWeb.Endpoint.url(),
        "code" => code
      })

      assert code =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert url == PairingsEngineWeb.Endpoint.url() <> "/p/nunki/join/" <> code
      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 15 * 60, 5

      example = Contract.example("pairing-link.nunki")
      assert String.replace(example["link"], example["code"], code) =~ ~r{/p/nunki/join/#{code}$}
    end

    test "a code is matched as given: base64url is not case-blind", %{scope: scope, t: t} do
      {:ok, %{code: code}} = Hall.create_join_code(scope, t)
      flipped = code |> String.upcase() |> String.replace(~r/[^A-Z]/, "Q")
      assert post_join(flipped, Contract.example("join-request")).status == 404
      assert post_join(code, Contract.example("join-request")).status == 200
    end

    test "an old 16-character code still joins, in any case", %{scope: scope, t: t} do
      legacy = "k3m9q2x7v4w8z6y5"

      PairingsEngine.Repo.insert!(%OpenPairingsNunki.JoinCode{
        code_hash: :crypto.hash(:sha256, legacy),
        expires_at: DateTime.add(DateTime.utc_now(:second), 600),
        tournament_id: t.id,
        created_by_id: scope.user.id
      })

      assert post_join(String.upcase(legacy), Contract.example("join-request")).status == 200
    end
  end

  describe "POST /p/nunki/join/:code" do
    test "every request example joins, and the answer is a join-response", %{scope: scope, t: t} do
      for {_name, body} <- Contract.examples("join-request") do
        {:ok, %{code: code}} = Hall.create_join_code(scope, t)
        conn = post_join(code, body)
        assert conn.status == 200
        Contract.assert_valid!("join-response", Jason.decode!(conn.resp_body))

        # Spent: the second time is a join-error.
        again = post_join(code, body)
        assert again.status == 410

        assert %{"error" => "used"} =
                 Contract.assert_valid!("join-error", Jason.decode!(again.resp_body))
      end
    end

    test "every refusal is a join-error, at the contract's status", %{scope: scope, t: t} do
      body = Contract.example("join-request")
      {:ok, %{code: code}} = Hall.create_join_code(scope, t)

      checks = [
        {post_join("no-such-code", body), 404, "unknown_code"},
        {post_join(code, %{body | "v" => 2}), 409, "version"},
        {post_join(code, Map.delete(body, "device")), 400, "bad_request"}
      ]

      for {conn, status, error} <- checks do
        assert conn.status == status

        assert %{"error" => ^error} =
                 Contract.assert_valid!("join-error", Jason.decode!(conn.resp_body))
      end

      {:ok, %{code: old}} = Hall.create_join_code(scope, t)

      PairingsEngine.Repo.update_all(OpenPairingsNunki.JoinCode,
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
      )

      expired = post_join(old, body)
      assert expired.status == 410

      assert %{"error" => "expired"} =
               Contract.assert_valid!("join-error", Jason.decode!(expired.resp_body))
    end
  end

  describe "the line" do
    test "welcome, settings and round are the contract's", %{scope: scope, t: t} do
      publish!(t, 1)
      {a, key} = announcer!(scope, t)
      hello = %{Contract.example("device-hello") | "device" => a.device_id, "key" => key}
      result = text_in(LinkSocket.new_state(), hello) |> assert_frames!()

      assert ["welcome", "settings", "round"] = Enum.map(frames(result), & &1["type"])
    end

    test "a round cut to a room carries the room", %{scope: scope, t: t} do
      {:ok, t} =
        PairingsEngine.Tournaments.update_tournament(t, %{
          "rooms" => [
            %{"name" => "Main hall", "boards" => "1-2"},
            %{"name" => "Annex", "boards" => "3"}
          ]
        })

      publish!(t, 1)
      {_a, state} = welcomed(scope, t)

      result =
        text_in(state, %{Contract.example("device-settings-nunki") | "room" => "Main hall"})

      assert {:ok, state} = result

      assert_receive {:nunki_settings_changed, _id} = changed
      result = LinkSocket.handle_info(changed, state) |> assert_frames!()

      assert %{"round" => %{"room" => "Main hall"}} =
               Enum.find(frames(result), &(&1["type"] == "round"))
    end

    test "a refused room is the settings frame with error", %{scope: scope, t: t} do
      {_a, state} = welcomed(scope, t)
      result = text_in(state, %{"type" => "settings", "room" => "Nowhere"}) |> assert_frames!()
      assert [%{"type" => "settings", "error" => "room"}] = frames(result)
    end

    test "the page's commands are the contract's frames", %{scope: scope, t: t} do
      publish!(t, 1)
      {_a, state} = welcomed(scope, t)

      {:ok, _} = Hall.start_countdown(scope, t, 5)
      :ok = Hall.cancel_countdown(scope, t)
      {:ok, _} = Hall.read_aloud(scope, t)
      :ok = Hall.stop_reading(scope, t)

      sent =
        for _ <- 1..4 do
          assert_receive {:nunki_send, _} = message
          message |> then(&LinkSocket.handle_info(&1, state)) |> assert_frames!() |> frames()
        end

      assert ["countdown", "countdown_cancel", "read", "stop"] =
               sent |> List.flatten() |> Enum.map(& &1["type"])
    end

    test "every device frame the contract has for Nunki is taken", %{scope: scope, t: t} do
      {_a, state} = welcomed(scope, t)

      state =
        for schema <- ~w(device-status-nunki device-settings-nunki device-ping),
            {_name, frame} <- Contract.examples(schema),
            reduce: state do
          state -> text_in(state, frame) |> assert_frames!() |> state()
        end

      pong = text_in(state, Contract.example("device-ping")) |> assert_frames!()
      assert [%{"type" => "pong"}] = frames(pong)

      assert {:stop, :normal, _} = text_in(state, Contract.example("device-leave"))
    end

    test "refused and leave are the contract's", %{scope: scope, t: t} do
      {a, key} = announcer!(scope, t)

      for {device, key, v, reason} <- [
            {a.device_id, "wrong", 1, "key"},
            {a.device_id, key, 2, "version"}
          ] do
        hello = %{Contract.example("device-hello") | "device" => device, "key" => key, "v" => v}
        result = text_in(LinkSocket.new_state(), hello) |> assert_frames!()
        assert [%{"reason" => ^reason}] = frames(result)
      end

      {a2, state} = welcomed(scope, t)
      :ok = Hall.revoke(scope, t, a2.id)
      assert_receive {:nunki_revoked, _} = revoked
      result = LinkSocket.handle_info(revoked, state) |> assert_frames!()
      assert [%{"type" => "leave"}] = frames(result)

      hello = %{Contract.example("device-hello") | "device" => a2.device_id, "key" => "x"}
      _ = text_in(LinkSocket.new_state(), hello) |> assert_frames!()
    end
  end
end
