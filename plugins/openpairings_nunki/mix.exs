defmodule OpenPairingsNunki.MixProject do
  use Mix.Project

  # Never compiled on its own. OpenPairings' hosted edition adds this
  # directory as a path dependency with `compile: false, app: false` and
  # compiles `lib/` together with the core (see openpairings_plugin.exs).
  # Everything the plugin uses - Ecto, Phoenix, WebSockAdapter, EQRCode,
  # Jason - the core already has, so there is nothing to declare. The file
  # exists because Mix wants one at the end of a path dependency.
  def project do
    [
      app: :openpairings_nunki,
      version: "0.6.0",
      elixir: "~> 1.18",
      deps: []
    ]
  end
end
