defmodule Nunki.Contracts.VendoredTest do
  @moduledoc """
  The vendored copy of OpenPairings' `hall-link-v1` itself: whole, as the
  provider lists it, and each example fitting its own schema. A copy
  somebody "fixed" by hand fails here before it fails anywhere more
  confusing; `mix contracts.check` (CI, daily) says when the provider has
  moved on.
  """

  use ExUnit.Case, async: true

  alias Nunki.Contract

  test "contracts.json lists exactly the vendored directories" do
    listed =
      Path.join(Contract.root(), "contracts.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(&{String.downcase(&1["repo"]), &1["name"]})

    present =
      for dir <- Path.wildcard(Path.join(Contract.root(), "*/*")), File.dir?(dir) do
        {dir |> Path.dirname() |> Path.basename(), Path.basename(dir)}
      end

    assert listed == [{"openpairings", "hall-link-v1"}]
    assert present == listed
  end

  test "a $ref into common.schema.json is followed, from the vendored copy" do
    # A version OpenPairings does not speak is refused through the $ref; a
    # validator that skipped the reference would let it pass.
    hello = Contract.example("device-hello")
    assert {:error, _} = Contract.validate("device-hello", %{hello | "v" => 2})
  end

  test "index.json lists every file there is, and nothing else" do
    index = Contract.read!("index.json")
    assert index["contract"] == "hall-link"
    assert index["version"] == 1
    assert index["files"] == Contract.files()
  end

  test "every example fits its schema, and every schema has one" do
    examples = Contract.examples()

    for {schema, name, data} <- examples do
      assert schema, "example #{name} belongs to no schema"
      Contract.assert_valid!(schema, data)
    end

    for schema <- Contract.schemas() do
      assert Enum.any?(examples, &(elem(&1, 0) == schema)), "#{schema} has no example"
    end
  end
end
