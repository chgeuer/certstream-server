import Config

config :certstream,
  # Defaults to "Certstream Server v{CURRENT_VERSION}"
  user_agent: :default,
  full_stream_url: "/full-stream",
  domains_only_url: "/domains-only"

config :logger,
  level: String.to_atom(System.get_env("LOG_LEVEL") || "info"),
  backends: [:console]

config :honeybadger,
  app: :certstream,
  exclude_envs: [:test],
  environment_name: :prod,
  use_logger: true

# Disable connection pooling for HTTP requests
config :hackney, use_default_pool: false
