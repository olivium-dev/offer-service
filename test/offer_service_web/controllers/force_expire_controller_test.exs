defmodule OfferServiceWeb.ForceExpireControllerTest do
  @moduledoc """
  HTTP contract for the S07/N3 force-expire test-seam:
  `POST /api/v1/offers/:offer_id/force-expire`.

  Two concerns are proven here:

    1. **The seam itself** — guarded by `OfferServiceWeb.Plugs.ServiceAuth`
       (feature flag + `X-Service-Auth-Key`): 200 when authorized, 401 on a
       missing/wrong key, 404 when the flag is off (seam invisible), 404 for a
       phantom offer.

    2. **BR-OFR-8 end-to-end** — after force-expiring an offer, the existing
       offer-scoped accept route returns **410 `offer_expired`** (the assertion
       N3 needs). The 410 branch already exists in the FallbackController; this
       test proves it is now reachable via a real API path.

  The test env sets `force_expire_seam_enabled: true` and a known
  `:service_token` (see `config/test.exs`).
  """
  use OfferServiceWeb.ConnCase, async: false

  import Mox

  alias OfferService.Auction.Offer
  alias OfferService.Repo

  @service_key "test-service-auth-key-do-not-use-in-prod"

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(OfferService.Clients.NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  defp client_id(who), do: "s07-#{who}-client-" <> Integer.to_string(:rand.uniform(9999))
  defp jeeber_id(who), do: "s07-#{who}-jeeber-" <> Integer.to_string(:rand.uniform(9999))

  describe "POST /api/v1/offers/:offer_id/force-expire (the seam)" do
    test "200 — valid service key drives the offer to expired", %{conn: conn} do
      request = insert_request!(%{client_id: client_id("sami")})
      offer = insert_submitted_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      conn =
        conn
        |> put_req_header("x-service-auth-key", @service_key)
        |> post("/api/v1/offers/#{offer.id}/force-expire")

      body = json_response(conn, 200)
      assert body["id"] == offer.id
      assert body["status"] == "expired"
      assert Repo.get!(Offer, offer.id).status == "expired"
    end

    test "401 — missing X-Service-Auth-Key header", %{conn: conn} do
      request = insert_request!()
      offer = insert_submitted_offer!(request)

      conn = post(conn, "/api/v1/offers/#{offer.id}/force-expire")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      # Offer must NOT have been mutated.
      assert Repo.get!(Offer, offer.id).status == "submitted"
    end

    test "401 — wrong X-Service-Auth-Key", %{conn: conn} do
      request = insert_request!()
      offer = insert_submitted_offer!(request)

      conn =
        conn
        |> put_req_header("x-service-auth-key", "definitely-not-the-key")
        |> post("/api/v1/offers/#{offer.id}/force-expire")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      assert Repo.get!(Offer, offer.id).status == "submitted"
    end

    test "404 — seam is invisible when the feature flag is off", %{conn: conn} do
      original = Application.get_env(:offer_service, :force_expire_seam_enabled)
      Application.put_env(:offer_service, :force_expire_seam_enabled, false)
      on_exit(fn -> Application.put_env(:offer_service, :force_expire_seam_enabled, original) end)

      request = insert_request!()
      offer = insert_submitted_offer!(request)

      conn =
        conn
        |> put_req_header("x-service-auth-key", @service_key)
        |> post("/api/v1/offers/#{offer.id}/force-expire")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
      assert Repo.get!(Offer, offer.id).status == "submitted"
    end

    test "404 — phantom offer id (authorized but no such offer)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-service-auth-key", @service_key)
        |> post("/api/v1/offers/#{uuid()}/force-expire")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "BR-OFR-8 — accepting an expired offer returns 410 (N3)" do
    test "force-expire then accept-as-CLIENT yields 410 offer_expired", %{conn: _conn} do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      offer = insert_submitted_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      # 1) Drive the offer to expired via the guarded seam.
      expire_conn =
        build_conn()
        |> put_req_header("x-service-auth-key", @service_key)
        |> post("/api/v1/offers/#{offer.id}/force-expire")

      assert json_response(expire_conn, 200)["status"] == "expired"

      # 2) The request-owning CLIENT attempts to accept the now-expired offer.
      accept_conn =
        build_conn()
        |> put_req_header("x-user-id", client)
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/offers/#{offer.id}/accept")

      # 3) BR-OFR-8: terminal/expired offer is Gone.
      body = json_response(accept_conn, 410)
      assert body["error"]["code"] == "offer_expired"
    end
  end
end
