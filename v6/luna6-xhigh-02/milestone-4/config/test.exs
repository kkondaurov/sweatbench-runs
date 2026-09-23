import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :group_stay, GroupStay.Repo,
  database:
    System.get_env("GROUP_STAY_DATABASE_PATH") ||
      Path.expand("../group_stay_test.db", __DIR__),
  pool_size: 1,
  pool: Ecto.Adapters.SQL.Sandbox

# Tests do not start the endpoint server. `mix phx.server` can still opt in through Phoenix's
# standard `:serve_endpoints` setting for cross-process development and migration checks.
config :group_stay, GroupStayWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("PORT") || "4002")
  ],
  secret_key_base: "emRdtaXdmAK0B9j606YuDdEdhXlgzH0o4acD+flNoMjxEsNKRtjXAEIdvY63P+MY"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
