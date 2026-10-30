defmodule NunkiWeb.CompactCssTest do
  use ExUnit.Case, async: true

  @css File.read!(Path.expand("../../assets/css/app.css", __DIR__))

  test "the 3.5 inch layout sits behind media queries, with 44 px targets" do
    [_, block] = String.split(@css, "==== compact-screen:", parts: 2)
    assert block =~ "@media (max-width: 520px), (max-height: 360px)"
    assert block =~ "min-height: 44px"
    assert block =~ ".nav a"
    assert block =~ ".language button"
    assert block =~ ".check input"
    # the portrait query is the only other media block
    assert String.split(block, "@media") |> length() == 3
  end
end
