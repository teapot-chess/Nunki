defmodule NunkiWeb.AccessGateTest do
  @moduledoc """
  The door: this machine's own browser is never asked for the PIN, any other
  is asked for every page (the hall screen too), the PIN is shown on the
  control page for the machine itself and nowhere else, and a change of PIN
  voids what was given.
  """

  use Nunki.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nunki.{AccessPin, DoorGuard}

  @endpoint NunkiWeb.Endpoint
  @lan {192, 168, 1, 20}

  defp unlock(conn \\ remote_conn(), pin \\ pin()) do
    post(conn, "/unlock", %{"unlock" => %{"pin" => pin}})
  end

  # The browser that has given the PIN, as its next request.
  defp unlocked do
    conn = unlock()
    assert redirected_to(conn) == "/"
    conn |> recycle() |> Map.put(:remote_ip, @lan)
  end

  defp count(html, selector) do
    html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
  end

  describe "who is asked" do
    test "this machine is not, on any page" do
      for path <- ["/", "/hall", "/help"] do
        assert local_conn() |> get(path) |> response(200), path
      end
    end

    test "another computer is, on every page, the hall screen included" do
      for path <- ["/", "/hall", "/hall?t=abc", "/help"] do
        conn = get(remote_conn(), path)
        assert redirected_to(conn) == "/unlock", path
      end
    end

    test "a LiveView socket of a stranger does not mount" do
      assert {:error, {:redirect, %{to: "/unlock"}}} = live(remote_conn(), "/")
    end

    test "a loopback peer that names another host, or comes through a proxy, is another computer" do
      conn = %{local_conn() | host: "www.example.com"}
      assert redirected_to(get(conn, "/")) == "/unlock"

      conn = local_conn() |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9")
      assert redirected_to(get(conn, "/")) == "/unlock"

      conn = local_conn() |> Plug.Conn.put_req_header("cf-connecting-ip", "203.0.113.9")
      assert redirected_to(get(conn, "/")) == "/unlock"
    end

    test "a LAN peer that says it is localhost is still another computer" do
      conn = %{remote_conn() | host: "localhost"}
      assert redirected_to(get(conn, "/")) == "/unlock"
    end

    test "the station's icon is not behind the door" do
      assert get(remote_conn(), "/favicon.svg").status == 200
    end
  end

  describe "the unlock page" do
    test "has a password field with a show button, and no keypad" do
      html = remote_conn() |> get("/unlock") |> html_response(200)

      assert count(html, "form#unlock-form input#unlock-pin[type=password][maxlength='64']") == 1
      assert count(html, "#unlock-show") == 1
      assert count(html, "[inputmode]") == 0
      assert count(html, "input[type=number], input[type=tel]") == 0
    end

    test "this machine is sent on to the control page" do
      assert redirected_to(get(local_conn(), "/unlock")) == "/"
    end

    test "a wrong PIN is turned away and gives nothing" do
      conn = unlock(remote_conn(), "000000")
      assert html_response(conn, 401)
      assert count(conn.resp_body, "#unlock-error") == 1

      assert redirected_to(conn |> recycle() |> Map.put(:remote_ip, @lan) |> get("/")) ==
               "/unlock"
    end

    test "a body that is not unlock[pin] is a wrong guess, not a crash" do
      conn = post(remote_conn(), "/unlock", %{"unlock" => "x"})
      assert html_response(conn, 401)
    end

    test "the right PIN opens every page, and the session holds a stamp, not the PIN" do
      conn = unlock()
      assert redirected_to(conn) == "/"
      assert Plug.Conn.get_session(conn, "pin_stamp") == AccessPin.stamp()
      assert Plug.Conn.get_session(conn, :live_socket_id) == AccessPin.socket_id()
      refute inspect(Plug.Conn.get_session(conn)) =~ pin()

      conn = recycle(conn) |> Map.put(:remote_ip, @lan)
      for path <- ["/", "/hall", "/help"], do: assert(response(get(conn, path), 200))
      assert {:ok, _view, _html} = live(conn, "/hall")
    end

    test "after the door it goes back to the page that was asked for" do
      conn = get(remote_conn(), "/hall?t=abc")

      conn =
        conn
        |> recycle()
        |> Map.put(:remote_ip, @lan)
        |> post("/unlock", %{"unlock" => %{"pin" => pin()}})

      assert redirected_to(conn) == "/hall?t=abc"
    end

    test "the wait is shown, and the right PIN is refused during it" do
      for _ <- 1..5, do: assert(html_response(unlock(remote_conn(), "000000"), 401))

      conn = unlock()
      assert html_response(conn, 429) =~ "Wait"
      assert Plug.Conn.get_session(conn, "pin_stamp") == nil
    end

    test "another address is not held up by it" do
      for _ <- 1..5, do: unlock(remote_conn(), "000000")
      assert redirected_to(unlock(remote_conn({192, 168, 1, 99}))) == "/"
    end

    test "40 wrong guesses from anywhere shut the door on every address that has failed" do
      for n <- 1..40, do: DoorGuard.claim({10, 1, 0, n})
      assert html_response(unlock(remote_conn({10, 1, 0, 1})), 429)
    end

    test "at that cap a device that has not failed yet still has 2 tries of its own" do
      for n <- 1..40, do: DoorGuard.claim({10, 1, 0, n})
      fresh = {192, 168, 1, 77}
      assert html_response(unlock(remote_conn(fresh), "000000"), 401)
      assert redirected_to(unlock(remote_conn(fresh))) == "/"
    end
  end

  describe "a change of PIN" do
    test "voids what was given" do
      conn = unlocked()
      assert response(get(conn, "/"), 200)

      AccessPin.set("a new pin 99")

      assert redirected_to(get(conn, "/")) == "/unlock"
      assert {:error, {:redirect, %{to: "/unlock"}}} = live(conn, "/")
    end

    test "does not touch this machine" do
      AccessPin.regenerate()
      assert response(get(local_conn(), "/"), 200)
    end
  end

  describe "the PIN on the screen" do
    test "this machine's control page shows it, with a form to change it and a random one" do
      {:ok, view, _html} = live(local_conn(), "/")

      assert has_element?(view, "#pin-panel")
      assert render(element(view, "#access-pin-value")) =~ pin()
      assert has_element?(view, "#pin-form input#pin-input[type=password][maxlength='64']")
      assert has_element?(view, "#pin-show")
      assert has_element?(view, "#pin-save")
      assert has_element?(view, "#pin-new")
    end

    test "there is no way to remove it" do
      {:ok, view, _html} = live(local_conn(), "/")
      refute has_element?(view, "#pin-panel [id*=remove]")
      refute has_element?(view, "#pin-panel button", "Remove")

      render_hook(view, "pin_remove", %{})
      render_hook(view, "pin_save", %{"pin" => %{"pin" => ""}})
      assert AccessPin.current() == pin()
      assert has_element?(view, "#pin-error")
    end

    test "a PIN of your own is saved, written, and said" do
      {:ok, view, _html} = live(local_conn(), "/")

      view |> form("#pin-form", pin: %{pin: "hall pin 2026"}) |> render_submit()

      assert AccessPin.current() == "hall pin 2026"
      assert File.read!(AccessPin.path()) == "hall pin 2026\n"
      assert render(element(view, "#access-pin-value")) =~ "hall pin 2026"
      assert render(view) =~ "PIN changed"
    end

    test "a bad one is said under the field and changes nothing" do
      {:ok, view, _html} = live(local_conn(), "/")

      view |> form("#pin-form", pin: %{pin: "12345"}) |> render_submit()
      assert has_element?(view, "#pin-error")
      assert AccessPin.current() == pin()

      view |> form("#pin-form", pin: %{pin: " 123456"}) |> render_submit()
      assert has_element?(view, "#pin-error")
      assert AccessPin.current() == pin()
    end

    test "New random PIN makes six digits, shows them, and voids the others" do
      conn = unlocked()
      {:ok, view, _html} = live(local_conn(), "/")

      view |> element("#pin-new") |> render_click()

      now = AccessPin.current()
      assert now =~ ~r/\A[0-9]{6}\z/
      assert now != pin()
      assert render(element(view, "#access-pin-value")) =~ now
      assert redirected_to(get(conn, "/")) == "/unlock"
    end

    test "an unlocked remote browser sees no PIN section and cannot use its events" do
      conn = unlocked()
      {:ok, view, html} = live(conn, "/")

      refute has_element?(view, "#pin-panel")
      refute html =~ pin()

      render_hook(view, "pin_save", %{"pin" => %{"pin" => "stolen over wifi"}})
      render_hook(view, "pin_new", %{})
      assert AccessPin.current() == pin()
    end

    test "the hall screen never shows it, here or elsewhere" do
      {:ok, view, html} = live(local_conn(), "/hall")
      refute html =~ pin()
      refute has_element?(view, "#pin-panel")
      refute has_element?(view, "#access-pin-value")

      {:ok, view, html} = live(unlocked(), "/hall")
      refute html =~ pin()
      refute has_element?(view, "#pin-panel")
    end

    test "the help page and the unlock page do not either" do
      refute local_conn() |> get("/help") |> html_response(200) =~ pin()
      refute remote_conn() |> get("/unlock") |> html_response(200) =~ pin()
    end
  end
end
