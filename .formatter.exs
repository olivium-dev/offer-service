[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  subdirectories: ["priv/*/migrations"]
]
