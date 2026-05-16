defmodule OfferServiceWeb.Router do
  use OfferServiceWeb, :router

  alias OfferServiceWeb.Plugs.AuthenticatedUser

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug AuthenticatedUser
  end

  scope "/", OfferServiceWeb do
    pipe_through :api

    get "/health", HealthController, :live
    get "/health/ready", HealthController, :ready
  end

  scope "/api/v1", OfferServiceWeb do
    pipe_through [:api, :authenticated]

    post "/requests/:request_id/offers/:offer_id/accept", OfferController, :accept
  end
end
