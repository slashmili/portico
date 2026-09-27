import Config

if config_env() == :dev do
  config :logger, level: :debug
end

config :portico_example,
  oauth_demo_expires_at: System.system_time(:second) + 3600,
  public_url: "http://127.0.0.1:" <> System.get_env("PORT", "4000"),
  start_server: config_env() != :test,
  port: String.to_integer(System.get_env("PORT", "4000")),
  allowed_origins:
    System.get_env("ALLOWED_ORIGINS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

# Stable across restarts/instances when supplied. The fallback is for the local
# showcase only: a fresh VM generates a new key and invalidates open forms.
# Recompiling or restarting the application inside the same VM retains the key.
config :portico, PorticoExample.MCP,
  elicitation_key:
    System.get_env("ELICITATION_KEY") || Base.encode64(:crypto.strong_rand_bytes(32))
