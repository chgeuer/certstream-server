import Config

# tls_versions: [
#   # :"tlsv1.3",
#   :"tlsv1.2"
# ]

config :logger,
  level: String.to_atom(System.get_env("LOG_LEVEL") || "info"),
  backends: [:console]
