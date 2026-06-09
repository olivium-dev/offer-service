defmodule OfferServiceWeb.RejectControllerTest do
  @moduledoc """
  HTTP contract for the offer-scoped CLIENT reject route (S08 / A5):
  `POST /api/v1/offers/:offer_id/reject`.

  This is the route the Jeeb gateway forwards `POST /offers/{offer_id}/reject`
  to. It carries no request_id — offer-service resolves it from the offer and
  authorizes on request-CLIENT ownership (the Client who created the request is
  the only authorized rejecter; the offer's own Jeeber -> 403). Mirrors the
  accept_by_offer controller test conventions (x-user-id auth header,
  Mox-stubbed NotificationClient). Auth identities use NON-UUID opaque
  `x-user-id` values (the gateway JWT `sub`) to exercise the uuid->text column
  widening.
  """
  use OfferServiceWeb.ConnCase, async: false

  import Mox

  alias OfferService.Auction.Offer
  alias OfferService.Clients.NotificationClientMock
  alias OfferService.Repo

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  defp client_id(who), do: "s08-#{who}-client-" <> Integer.to_string(:rand.uniform(9999))
  defp jeeber_id(who), do: "s08-#{who}-jeeber-" <> Integer.to_string(:rand.uniform(9999))

  describe "POST /api/v1/offers/:offer_id/reject" do
    test "200 — the request CLIENT rejects a Jeeber offer; status becomes rejected",
         %{conn: conn} do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      offer = insert_submitted_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      conn =
        conn
        |> put_req_header("x-user-id", client)
        |> post("/api/v1/offers/#{offer.id}/reject")

      body = json_response(conn, 200)

      assert body["id"] == offer.id
      assert body["status"] == "rejected"
      # The request is NOT closed by a reject — it stays open for other bids.
      assert Repo.get!(Offer, offer.id).status == "rejected"
    end

    test "403 — the offer's OWN Jeeber cannot reject its own bid", %{conn: conn} do
      request = insert_request!(%{client_id: client_id("sami")})
      offer = insert_submitted_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      conn =
        conn
        |> put_req_header("x-user-id", offer.jeeber_id)
        |> post("/api/v1/offers/#{offer.id}/reject")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
      assert Repo.get!(Offer, offer.id).status == "submitted"
    end

    test "403 — a different client (not the request owner) is rejected", %{conn: conn} do
      request = insert_request!(%{client_id: client_id("sami")})
      offer = insert_submitted_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      conn =
        conn
        |> put_req_header("x-user-id", client_id("intruder"))
        |> post("/api/v1/offers/#{offer.id}/reject")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "404 — phantom offer id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", client_id("sami"))
        |> post("/api/v1/offers/#{uuid()}/reject")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "401 — missing x-user-id header", %{conn: conn} do
      conn = post(conn, "/api/v1/offers/#{uuid()}/reject")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "409 — re-rejecting an already-rejected offer (already_rejected)", %{conn: conn} do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      offer = insert_submitted_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      conn0 = put_req_header(conn, "x-user-id", client)
      assert json_response(post(conn0, "/api/v1/offers/#{offer.id}/reject"), 200)

      conn1 =
        build_conn()
        |> put_req_header("x-user-id", client)
        |> post("/api/v1/offers/#{offer.id}/reject")

      assert json_response(conn1, 409)["error"]["code"] == "already_rejected"
    end
  end
end
