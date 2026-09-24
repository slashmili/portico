import Config

if config_env() == :dev do
  config :logger, level: :debug
end

config :portico_example,
  start_server: config_env() != :test,
  port: String.to_integer(System.get_env("PORT", "4000")),
  allowed_origins:
    System.get_env("ALLOWED_ORIGINS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
