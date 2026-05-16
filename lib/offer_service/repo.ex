defmodule OfferService.Repo do
  use Ecto.Repo,
    otp_app: :offer_service,
    adapter: Ecto.Adapters.Postgres
end
