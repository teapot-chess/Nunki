defmodule NunkiWeb.HelpLiveTest do
  @moduledoc "The manual is there, in both languages, with the same sections."

  use Nunki.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint NunkiWeb.Endpoint

  @sections ~w(what join speech hall voices update advanced data trouble)

  test "English" do
    {:ok, view, _html} = live(build_conn(), "/help")
    assert has_element?(view, "#manual")
    for s <- @sections, do: assert(has_element?(view, "#manual-#{s}"), s)
  end

  test "Dutch" do
    conn = post(build_conn(), "/locale", %{"locale" => "nl", "return_to" => "/help"})
    assert redirected_to(conn) == "/help"
    {:ok, view, html} = live(recycle(conn), "/help")
    assert html =~ "omroeper"
    for s <- @sections, do: assert(has_element?(view, "#manual-#{s}"), s)
  end

  test "a newer version is announced on the help page too, pointing at the control page" do
    {:ok, view, _html} = live(build_conn(), "/help")
    refute has_element?(view, "#update-banner")

    Nunki.Updates.Checker.put(%{
      version: "9.9.9",
      tag: "v9.9.9",
      url: "https://example.invalid",
      size: nil,
      asset: "a",
      no_build: false
    })

    on_exit(fn -> Nunki.Updates.Checker.forget() end)

    {:ok, view, _html} = live(build_conn(), "/help")
    assert has_element?(view, "#update-banner", "9.9.9")
    assert has_element?(view, "#update-banner-control[href='/']")
  end

  test "the hall screen never shows it" do
    Nunki.Updates.Checker.put(%{
      version: "9.9.9",
      tag: "v9.9.9",
      url: "https://example.invalid",
      size: nil,
      asset: "a",
      no_build: false
    })

    on_exit(fn -> Nunki.Updates.Checker.forget() end)

    {:ok, view, _html} = live(build_conn(), "/hall")
    refute has_element?(view, "#update-banner")
  end

  test "the favicon is the mark on an ink tile, in the night accent" do
    conn = get(build_conn(), "/favicon.svg")
    assert conn.status == 200
    assert conn.resp_body =~ "#f0c46a"
    assert conn.resp_body =~ "#1b1b1a"
  end
end
