defmodule NunkiWeb.LocalApiTest do
  @moduledoc """
  The local control API (docs/local-api.md): its shapes, its answers to bad
  input, and that nobody but this machine gets in.
  """

  use Nunki.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Nunki.{Countdown, Hall, Speaker, Store}

  @endpoint NunkiWeb.Endpoint

  defp tournament(name, round \\ nil) do
    {:ok, id} =
      Store.add_tournament(%{
        "server" => "fake",
        "socket" => "ws://127.0.0.1:1/p/nunki/link/#{name}",
        "key" => "k",
        "tournament" => %{"id" => name, "name" => name}
      })

    if round, do: Store.update_tournament(id, &Map.put(&1, "round", round))
    id
  end

  defp api(method, path, body \\ nil), do: on(local_conn(), method, path, body)

  defp on(conn, method, path, body) do
    conn =
      if body,
        do: put_req_header(conn, "content-type", "application/json"),
        else: conn

    dispatch(conn, @endpoint, method, "/api/local/v1" <> path, body && Jason.encode!(body))
  end

  test "GET /state: the whole shape, nothing joined" do
    body = api(:get, "/state") |> json_response(200)

    assert body == %{
             "screen" => "live",
             "audio" => true,
             "hall_tournament" => nil,
             "screens" => %{
               "hdmi1" => %{
                 "mode" => "live",
                 "tournament" => nil,
                 "shows" => nil,
                 "countdown" => nil
               },
               "hdmi2" => %{
                 "mode" => "live",
                 "tournament" => nil,
                 "shows" => nil,
                 "countdown" => nil
               }
             },
             "tournaments" => [],
             "countdown" => nil,
             "speaking" => false,
             "version" => Nunki.version()
           }
  end

  test "GET /state: tournaments and the countdown of what screen 1 shows" do
    id = tournament("Open A", payload(3))
    {:ok, _} = Countdown.start(id, 4, 300)

    body = api(:get, "/state") |> json_response(200)
    assert [%{"id" => ^id, "name" => "Open A", "connected" => false}] = body["tournaments"]

    assert %{"tournament_id" => ^id, "round" => 4, "ends_at" => ends_at, "started" => false} =
             body["countdown"]

    {:ok, at, 0} = DateTime.from_iso8601(ends_at)
    assert DateTime.diff(at, DateTime.utc_now()) in 290..301
    assert body["screens"]["hdmi1"]["shows"] == id
  end

  test "POST /screen sets a screen's mode; hdmi1 when no screen is named" do
    body = api(:post, "/screen", %{"mode" => "black"}) |> json_response(200)
    assert body["screen"] == "black"
    assert body["screens"]["hdmi1"]["mode"] == "black"

    body = api(:post, "/screen", %{"screen" => "hdmi2", "mode" => "paused"}) |> json_response(200)
    assert body["screens"]["hdmi2"]["mode"] == "paused"
    assert Hall.screen("hdmi2")["mode"] == "paused"
  end

  test "POST /screen: bad input is a 422 with words" do
    for bad <- [%{"mode" => "dim"}, %{}, %{"mode" => 1}, %{"screen" => "hdmi3", "mode" => "live"}] do
      conn = api(:post, "/screen", bad)
      assert %{"error" => error} = json_response(conn, 422), inspect(bad)
      assert is_binary(error)
    end

    assert Hall.screen("hdmi1")["mode"] == "live"
  end

  test "a body that is not JSON, or not sent as JSON" do
    conn =
      local_conn()
      |> put_req_header("content-type", "application/json")
      |> dispatch(@endpoint, :post, "/api/local/v1/screen", "{nope")

    assert %{"error" => _} = json_response(conn, 422)

    conn =
      local_conn()
      |> put_req_header("content-type", "text/plain")
      |> dispatch(@endpoint, :post, "/api/local/v1/screen", ~s({"mode":"black"}))

    assert %{"error" => _} = json_response(conn, 415)

    conn =
      local_conn()
      |> put_req_header("content-type", "application/json")
      |> dispatch(@endpoint, :post, "/api/local/v1/screen", "[1]")

    assert json_response(conn, 422)
  end

  test "POST /audio switches the sound, and says so" do
    body = api(:post, "/audio", %{"enabled" => false}) |> json_response(200)
    assert body["audio"] == false
    refute Hall.audio?()

    assert %{"error" => _} = api(:post, "/audio", %{"enabled" => "no"}) |> json_response(422)
    assert api(:post, "/audio", %{"enabled" => true}) |> json_response(200) |> Map.get("audio")
  end

  test "POST /hall_tournament: a joined id or null, per screen" do
    a = tournament("Open A")
    b = tournament("Open B")

    body = api(:post, "/hall_tournament", %{"id" => b}) |> json_response(200)
    assert body["hall_tournament"] == b
    assert body["screens"]["hdmi1"]["shows"] == b

    body = api(:post, "/hall_tournament", %{"screen" => "hdmi2", "id" => a}) |> json_response(200)
    assert body["screens"]["hdmi2"]["tournament"] == a

    body = api(:post, "/hall_tournament", %{"id" => nil}) |> json_response(200)
    assert body["hall_tournament"] == nil
    assert body["screens"]["hdmi1"]["shows"] == hd(Store.tournaments())["id"]

    assert api(:post, "/hall_tournament", %{"id" => "nope"}) |> json_response(422)
    assert api(:post, "/hall_tournament", %{}) |> json_response(422)
    assert api(:post, "/hall_tournament", %{"screen" => "tv", "id" => nil}) |> json_response(422)
  end

  test "POST /identify tells the screens; POST /stop stops speaking" do
    Nunki.subscribe()
    assert api(:post, "/identify") |> json_response(200)
    assert_receive {:identify, 5_000}

    Fake.hold()
    Speaker.say(["a line"], "en")
    eventually(fn -> Speaker.speaking?() end)
    refute api(:post, "/stop") |> json_response(200) |> Map.get("speaking")
  end

  describe "only this machine" do
    test "a LAN peer is refused, PIN or not, listen mode or not" do
      Application.put_env(:nunki, :listen, :lan)
      on_exit(fn -> Application.delete_env(:nunki, :listen) end)

      for ip <- [{192, 168, 1, 20}, {100, 101, 102, 103}, {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1}] do
        conn = on(remote_conn(ip), :get, "/state", nil)
        assert %{"error" => _} = json_response(conn, 403), inspect(ip)
        conn = on(remote_conn(ip), :post, "/screen", %{"mode" => "black"})
        assert json_response(conn, 403)
      end

      assert Hall.screen("hdmi1")["mode"] == "live"
    end

    test "::1 is this machine" do
      conn = %{local_conn() | remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}
      assert on(conn, :get, "/state", nil) |> json_response(200)
    end

    test "a loopback peer that came through a proxy, tailscale serve included, is not" do
      for header <- ["x-forwarded-for", "tailscale-user-login"] do
        conn = local_conn() |> put_req_header(header, "somebody")
        assert on(conn, :get, "/state", nil) |> json_response(403), header
      end
    end

    test "a web page in this machine's browser is not" do
      conn = local_conn() |> put_req_header("origin", "http://attacker.example")
      assert on(conn, :post, "/screen", %{"mode" => "black"}) |> json_response(403)
      assert Hall.screen("hdmi1")["mode"] == "live"
    end

    test "a host name Nunki does not answer to never gets this far" do
      conn = local_conn() |> Map.put(:host, "attacker.example")
      assert on(conn, :get, "/state", nil).status == 403
    end
  end
end
