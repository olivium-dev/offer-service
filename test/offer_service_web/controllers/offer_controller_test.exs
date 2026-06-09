defmodule OfferServiceWeb.OfferControllerTest do
  use OfferServiceWeb.ConnCase, async: false

  import Mox

  alias OfferService.Clients.NotificationClientMock

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  describe "POST /api/v1/requests/:request_id/offers/:offer_id/accept" do
    test "200 returns serialized result including 4-digit OTP", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request)

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      # chat_thread_id is always nil — the gateway BFF owns chat provisioning
      # (fix C / no-coupling LAW); offer-service holds no chat client.
      assert %{
               "accepted_offer" => %{"id" => accepted_id, "status" => "accepted"},
               "rejected_offer_ids" => [],
               "chat_thread_id" => nil,
               "otp_code" => otp,
               "request" => %{"status" => "accepted"}
             } = json_response(conn, 200)

      assert accepted_id == offer.id
      assert otp =~ ~r/^\d{4}$/
      assert ["false"] = Plug.Conn.get_resp_header(conn, "x-idempotency-replay")
    end

    test "401 when x-user-id header is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/#{uuid()}/offers/#{uuid()}/accept")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "400 when Idempotency-Key header is missing (JEB-49 / AC2)", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request)

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert json_response(conn, 400)["error"]["code"] == "idempotency_key_required"
    end

    test "403 when actor is not the request owner", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request)

      conn =
        conn
        |> put_req_header("x-user-id", uuid())
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "409 high-fee confirmation required", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request, %{fee_cents: 9_900})

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert json_response(conn, 409)["error"]["code"] == "conflict"
      assert json_response(conn, 409)["error"]["message"] =~ "high-fee"
    end

    test "200 high-fee accepted when confirm_high_fee=true", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request, %{fee_cents: 9_900})

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post(
          "/api/v1/requests/#{request.id}/offers/#{offer.id}/accept",
          %{confirm_high_fee: true}
        )

      assert json_response(conn, 200)["accepted_offer"]["status"] == "accepted"
    end

    test "404 when request id is not a UUID", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", uuid())
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/not-a-uuid/offers/#{uuid()}/accept")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "410 when request is expired (JEB-49 / AC4)", %{conn: conn} do
      request = insert_request!(%{status: "expired"})
      offer = insert_offer!(request)

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert json_response(conn, 410)["error"]["code"] == "request_expired"
    end

    test "410 when request is cancelled (JEB-49 / AC4)", %{conn: conn} do
      request = insert_request!(%{status: "cancelled"})
      offer = insert_offer!(request)

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert json_response(conn, 410)["error"]["code"] == "request_cancelled"
    end

    test "409 already_accepted returns winner_user_id (JEB-49 / AC3)", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request)
      losing_offer = insert_offer!(request)

      first_conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", "idem-first-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert json_response(first_conn, 200)["accepted_offer"]["id"] == offer.id

      second_conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", "idem-second-" <> Ecto.UUID.generate())
        |> post("/api/v1/requests/#{request.id}/offers/#{losing_offer.id}/accept")

      body = json_response(second_conn, 409)
      assert body["error"]["code"] == "already_accepted"
      assert body["error"]["winner_user_id"] == offer.jeeber_id
    end

    test "200 replay returns identical body & x-idempotency-replay=true (JEB-49 / AC2)", %{
      conn: conn
    } do
      request = insert_request!()
      offer = insert_offer!(request)

      key = "idem-replay-" <> Ecto.UUID.generate()

      first =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", key)
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      first_body = json_response(first, 200)
      assert ["false"] = Plug.Conn.get_resp_header(first, "x-idempotency-replay")

      # Replay: same client_id, same key, same payload → saga not re-run, no
      # second OTP, identical body.
      second =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", key)
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      second_body = json_response(second, 200)
      assert ["true"] = Plug.Conn.get_resp_header(second, "x-idempotency-replay")

      assert second_body["accepted_offer"]["id"] == first_body["accepted_offer"]["id"]
      assert second_body["otp_code"] == first_body["otp_code"]
      assert second_body["chat_thread_id"] == first_body["chat_thread_id"]
    end

    test "422 when same Idempotency-Key is reused with a divergent payload (JEB-49 / AC2)", %{
      conn: conn
    } do
      request = insert_request!()
      offer_a = insert_offer!(request)
      offer_b = insert_offer!(request)

      key = "idem-mismatch-" <> Ecto.UUID.generate()

      first =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", key)
        |> post("/api/v1/requests/#{request.id}/offers/#{offer_a.id}/accept")

      assert json_response(first, 200)["accepted_offer"]["id"] == offer_a.id

      second =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", request.client_id)
        |> put_req_header("idempotency-key", key)
        |> post("/api/v1/requests/#{request.id}/offers/#{offer_b.id}/accept")

      assert json_response(second, 422)["error"]["code"] == "idempotency_mismatch"
    end

    test "GET /health returns 200", %{conn: conn} do
      assert json_response(get(conn, "/health"), 200) == %{"status" => "ok"}
    end
  end
end
