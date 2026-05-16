defmodule OfferServiceWeb.OfferControllerTest do
  use OfferServiceWeb.ConnCase, async: false

  import Mox

  alias OfferService.Clients.{ChatClientMock, NotificationClientMock}

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
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "thread-1"}} end)

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert %{
               "accepted_offer" => %{"id" => accepted_id, "status" => "accepted"},
               "rejected_offer_ids" => [],
               "chat_thread_id" => "thread-1",
               "otp_code" => otp,
               "request" => %{"status" => "accepted"}
             } = json_response(conn, 200)

      assert accepted_id == offer.id
      assert otp =~ ~r/^\d{4}$/
    end

    test "401 when x-user-id header is missing", %{conn: conn} do
      conn = post(conn, "/api/v1/requests/#{uuid()}/offers/#{uuid()}/accept")
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "403 when actor is not the request owner", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request)

      conn =
        conn
        |> put_req_header("x-user-id", uuid())
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "409 high-fee confirmation required", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request, %{fee_cents: 9_900})

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
        |> post("/api/v1/requests/#{request.id}/offers/#{offer.id}/accept")

      assert json_response(conn, 409)["error"]["code"] == "conflict"
      assert json_response(conn, 409)["error"]["message"] =~ "high-fee"
    end

    test "200 high-fee accepted when confirm_high_fee=true", %{conn: conn} do
      request = insert_request!()
      offer = insert_offer!(request, %{fee_cents: 9_900})
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "thread-hf"}} end)

      conn =
        conn
        |> put_req_header("x-user-id", request.client_id)
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
        |> post("/api/v1/requests/not-a-uuid/offers/#{uuid()}/accept")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "GET /health returns 200", %{conn: conn} do
      assert json_response(get(conn, "/health"), 200) == %{"status" => "ok"}
    end
  end
end
