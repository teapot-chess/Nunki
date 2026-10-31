defmodule OpenPairingsNunki.Contract do
  @moduledoc """
  OpenPairings' `hall-link-v1`, as the Nunki repository vendors it
  (`priv/contracts/vendor/openpairings/hall-link-v1/`, kept current by `mix
  contracts.sync` there), for the plugin's tests: the server half held to
  the same files the device half is.

  The plugin's tests run inside an OpenPairings checkout, whose own
  `PairingsEngineWeb.ContractHelpers` also sets ex_json_schema's (global)
  remote resolver. `resolve/1` answers hall-link-v1's addresses from the
  vendored copy and hands anything else to the core's resolver, so either
  module may resolve while the other's is set; the tests that use it are
  `async: false` all the same.
  """

  import ExUnit.Assertions

  @dir Path.expand("../../../../priv/contracts/vendor/openpairings/hall-link-v1", __DIR__)
  @prefix "https://raw.githubusercontent.com/teapot-chess/openpairings/main/priv/contracts/hall-link-v1/"

  def dir, do: @dir

  def read!(file), do: @dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  @doc "An example by its name: `example(\"device-hello\")`."
  def example(name), do: read!("examples/#{name}.json")

  @doc "`[{name, data}]`: the examples of schema `schema` (`x.json`, `x.<variant>.json`)."
  def examples(schema) do
    for path <- Path.wildcard(Path.join(@dir, "examples/*.json")),
        name = Path.basename(path, ".json"),
        name == schema or String.starts_with?(name, schema <> "."),
        do: {name, path |> File.read!() |> Jason.decode!()}
  end

  @doc "The schema `name`, resolved."
  def schema(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        resolved =
          :global.trans({__MODULE__, self()}, fn ->
            Application.put_env(:ex_json_schema, :remote_schema_resolver, {__MODULE__, :resolve})
            ExJsonSchema.Schema.resolve(read!("#{name}.schema.json"))
          end)

        :persistent_term.put(key, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  @doc "Asserts that `data` (put through JSON first, as the wire would) fits schema `name`."
  def assert_valid!(name, data) do
    json = data |> Jason.encode!() |> Jason.decode!()

    case ExJsonSchema.Validator.validate(schema(name), json) do
      :ok ->
        json

      {:error, errors} ->
        flunk("""
        does not fit hall-link-v1 #{name}.schema.json:
        #{Enum.map_join(errors, "\n", fn {message, path} -> "  #{path}: #{message}" end)}
        in: #{Jason.encode!(json)}
        """)
    end
  end

  @doc false
  def resolve(@prefix <> file), do: read!(file)
  def resolve(url), do: PairingsEngineWeb.ContractHelpers.resolve_remote(url)
end
