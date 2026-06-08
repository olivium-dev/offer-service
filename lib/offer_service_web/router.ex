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

    # Gateway request-bridge: mirror a gateway-created request so offers resolve.
    post "/requests", RequestController, :create

    post "/requests/:request_id/offers", OfferController, :submit
    put "/requests/:request_id/offers/:offer_id", OfferController, :edit
    delete "/requests/:request_id/offers/:offer_id", OfferController, :withdraw
    post "/requests/:request_id/offers/:offer_id/accept", OfferController, :accept

    # S07 / OS-4: offer-scoped accept for the gateway's POST /offers/{id}/accept.
    # Resolves the request from the offer; offer-owner gated. Additive — the
    # request-scoped accept route above is unchanged.
    post "/offers/:offer_id/accept", OfferController, :accept_by_offer
  end
end
