import Config

File.mkdir_p!(Path.expand("../tmp/test/data", __DIR__))

config :nunki, NunkiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4072],
  secret_key_base: "tK8sW2nQ5vB9xL4mR7cJ1hF6dG3pZ0aY8eU5iO2wN7qT4rS1kM9bV6xC3lH0jD5f",
  server: false

config :nunki,
  # Phoenix's test connections ask for this host.
  extra_hosts: ["www.example.com"],
  data_dir: Path.expand("../tmp/test/data", __DIR__),
  # Never a sound: every utterance goes to the fake, which writes it down.
  voice_backend: Nunki.Voice.Fake,
  start_links: false,
  # No launcher secret, no token file; the tests that need them start their
  # own `Nunki.LauncherDetails`.
  launcher_details: false,
  updates_timer: false,
  install_kind: :manual,
  # "Start with Windows" must not ask the registry of the machine the tests run on.
  autostart_cmd: &Nunki.NoReg.cmd/3,
  # The countdown's clock, set by the test instead of waited for.
  clock: Nunki.TestClock

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view, enable_expensive_runtime_checks: true

config :phoenix, sort_verified_routes_query_params: true
config :ex_json_schema, :remote_schema_resolver, {Nunki.Contract, :resolve}
