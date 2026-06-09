defmodule OfferServiceWeb.Router do
  use OfferServiceWeb, :router

  alias OfferServiceWeb.Plugs.{AuthenticatedUser, ServiceAuth}

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug AuthenticatedUser
  end

  # Guards privileged internal/test-only routes: feature-flag-gated
  # (default off → 404) + `X-Service-Auth-Key` service-token check. Never
  # combined with `:authenticated` — the caller is a trusted internal operator,
  # not an end user.
  pipeline :service_authenticated do
    plug ServiceAuth
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

  # S07 / N3 force-expire test-seam. Guarded by ServiceAuth (feature flag +
  # X-Service-Auth-Key), NOT by AuthenticatedUser. Default-off: invisible (404)
  # to real traffic unless `:force_expire_seam_enabled` is explicitly turned on.
  scope "/api/v1", OfferServiceWeb do
    pipe_through [:api, :service_authenticated]

    post "/offers/:offer_id/force-expire", OfferController, :force_expire
  end
end
