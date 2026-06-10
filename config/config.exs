import Config

# Shared configuration for all environments
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

if config_env() == :test do
  # The test suites drive the schedule clock deterministically via
  # Schedule.tick_at/1 — a real wall-clock tick would race them.
  config :skein_runtime, schedule_auto_tick: false
end
