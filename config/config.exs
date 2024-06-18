import Config

config :certstream,
  # Defaults to "Certstream Server v{CURRENT_VERSION}"
  # user_agent: "Certstream Server",
  full_stream_url: "/full-stream",
  domains_only_url: "/domains-only"

# tls_versions: [
#   # :"tlsv1.3",
#   :"tlsv1.2"
# ]

config :logger,
  level: String.to_atom(System.get_env("LOG_LEVEL") || "info"),
  backends: [:console]
