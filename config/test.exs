import Config

config :manifests, Oban, testing: :manual

config :ash,
  policies: [show_policy_breakdowns?: true],
  keyset_signing_secret: "Ywb9x9hyN/anD4NPdhW3YZBcHkCqYIbjV7c6nKumkWY",
  disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :manifests, Manifests.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "manifests_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :manifests, ManifestsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "OQbDK0BMlmyPd1PmNa6wBB9uS8d+vX9oEr1u/JOu4PnrTlpro8hrteUVXl0UML7Y",
  server: false

# In test we don't send emails
config :manifests, Manifests.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
