import Config

# Where Nunki keeps what it must not lose: state.json (the device's id and
# name, the joined tournaments and their keys, the settings). Overridden per
# environment and by NUNKI_DATA.
config :nunki, data_dir: Path.expand("../data", __DIR__)

# Whether it asks GitHub, on a timer, if a newer version is out. Off in
# tests, which ask when they mean to.
config :nunki, updates_timer: true

# Whether the links to the joined tournaments start with the application.
# Off in tests, which start what they need.
config :nunki, start_links: true

config :nunki, NunkiWeb.Gettext, default_locale: "en", locales: ~w(en nl)

config :phoenix_live_view, :colocated_assets, disable_symlink_warning: true

config :nunki, NunkiWeb.Endpoint,
  url: [host: "localhost"],
  # The hosts Nunki answers to, not "localhost" alone (a hall PC is opened by
  # its address) and not "anything" (DNS rebinding): see `NunkiWeb.HostGuard`.
  check_origin: {NunkiWeb.HostGuard, :origin_allowed?, []},
  adapter: Bandit.PhoenixAdapter,
  # At a stop, open connections (the hall screen, the control page) get
  # three seconds to go, not Bandit's fifteen.
  http: [thousand_island_options: [shutdown_timeout: 3_000]],
  render_errors: [formats: [html: NunkiWeb.ErrorHTML], layout: false],
  pubsub_server: Nunki.PubSub,
  live_view: [signing_salt: "q3Ztm8nE"]

config :phoenix_live_view, root_tag_attribute: "phx-r"

config :esbuild,
  version: "0.25.4",
  nunki: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2022 --outbase=. --outdir=../priv/static/assets --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# What never goes into a log, at any level: the join code in a link, a key.
config :phoenix, :filter_parameters, ["link", "code", "key", "token", "secret", "pin"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
