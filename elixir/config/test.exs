import Config

config :symphony_elixir,
       :state_db_path,
       Path.join(
         System.tmp_dir!(),
         "symphony-test-#{System.system_time(:nanosecond)}-#{:rand.uniform(999_999)}.db"
       )
