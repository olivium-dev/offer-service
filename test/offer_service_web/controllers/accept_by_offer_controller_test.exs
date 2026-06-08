defmodule OfferServiceWeb.AcceptByOfferControllerTest do
  @moduledoc """
  HTTP contract for the offer-scoped accept route (S07 / OS-4):
  `POST /api/v1/offers/:offer_id/accept`.

  This is the route the Jeeb gateway forwards `POST /offers/{offer_id}/accept`
  to — it carries no request_id, so offer-service resolves it from the offer and
  authorizes on OFFER ownership. Mirrors the request-scoped controller test
  conventions (x-user-id auth header, idempotency-key header, Mox-stubbed
  cross-service clients).
  """
  use OfferServiceWeb.ConnCase, async: false

  import Mox

  alias OfferService.Clients.{ChatClientMock, NotificationClientMock}

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  describe "POST /api/v1/offers/:offer_id/accept" do
    test "200 — the offer's Jeeber accepts and gets the serialized accept envelope", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request)
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "thread-os4"}} end)

      conn =
        conn
        |> put_req_header("x-user-id", offer.jeeber_id)
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/offers/#{offer.id}/accept")

      body = json_response(conn, 200)

      assert body["accepted_offer"]["id"] == offer.id
      assert body["accepted_offer"]["status"] == "accepted"
      assert body["request"]["status"] == "accepted"
      assert body["chat_thread_id"] == "thread-os4"
      assert body["otp_code"] =~ ~r/^\d{4}$/
      assert ["false"] = Plug.Conn.get_resp_header(conn, "x-idempotency-replay")
    end

    test "403 — a different Jeeber (not the offer owner) is rejected and the saga never runs",
         %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request)

      # No ChatClientMock expectation: a 200 would fail verify_on_exit!.
      conn =
        conn
        |> put_req_header("x-user-id", uuid())
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/offers/#{offer.id}/accept")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "404 — phantom offer id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", uuid())
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/offers/#{uuid()}/accept")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "401 — missing x-user-id header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/offers/#{uuid()}/accept")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "400 — missing Idempotency-Key header", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request)

      conn =
        conn
        |> put_req_header("x-user-id", offer.jeeber_id)
        |> post("/api/v1/offers/#{offer.id}/accept")

      assert json_response(conn, 400)["error"]["code"] == "idempotency_key_required"
    end
  end
end
