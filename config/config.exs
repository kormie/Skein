import Config

# Shared configuration for all environments
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
