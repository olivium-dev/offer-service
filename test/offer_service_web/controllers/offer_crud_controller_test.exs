defmodule OfferServiceWeb.OfferCrudControllerTest do
  @moduledoc """
  HTTP-level acceptance for the JEB-48 CRUD endpoints. The lower-level
  semantics are already covered by `OfferService.Auction.Submit/Edit/Withdraw`
  unit tests; this suite only verifies routing, status codes, and error
  body shape.
  """

  use OfferServiceWeb.ConnCase, async: false

  describe "POST /api/v1/requests/:request_id/offers" do
    test "201 returns the submitted offer (AC1)", %{conn: conn} do
      request = insert_request!()
      jeeber = uuid()

      conn =
        conn
        |> put_req_header("x-user-id", jeeber)
        |> post("/api/v1/requests/#{request.id}/offers", %{
          "fee_cents" => 1_500,
          "eta_minutes" => 25,
          "note" => "ASAP"
        })

      body = json_response(conn, 201)
      assert body["status"] == "submitted"
      assert body["edits_count"] == 0
      assert body["fee_cents"] == 1_500
      assert body["eta_minutes"] == 25
      assert body["note"] == "ASAP"
      assert body["jeeber_id"] == jeeber
      assert body["request_id"] == request.id
    end

    test "401 when x-user-id missing", %{conn: conn} do
      conn =
        post(conn, "/api/v1/requests/#{uuid()}/offers", %{
          "fee_cents" => 1_500,
          "eta_minutes" => 25
        })

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "404 when request_id is not a UUID", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", uuid())
        |> post("/api/v1/requests/not-a-uuid/offers", %{
          "fee_cents" => 1_500,
          "eta_minutes" => 25
        })

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "404 when request does not exist", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", uuid())
        |> post("/api/v1/requests/#{uuid()}/offers", %{
          "fee_cents" => 1_500,
          "eta_minutes" => 25
        })

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "422 on invalid payload", %{conn: conn} do
      request = insert_request!()

      conn =
        conn
        |> put_req_header("x-user-id", uuid())
        |> post("/api/v1/requests/#{request.id}/offers", %{
          "fee_cents" => 0,
          "eta_minutes" => 0
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "validation_failed"
    end

    test "409 when same jeeber tries to submit twice", %{conn: conn} do
      request = insert_request!()
      jeeber = uuid()

      assert _ =
               conn
               |> put_req_header("x-user-id", jeeber)
               |> post("/api/v1/requests/#{request.id}/offers", %{
                 "fee_cents" => 1_000,
                 "eta_minutes" => 10
               })
               |> json_response(201)

      conn2 =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", jeeber)
        |> post("/api/v1/requests/#{request.id}/offers", %{
          "fee_cents" => 1_100,
          "eta_minutes" => 12
        })

      assert json_response(conn2, 409)["error"]["code"] == "conflict"
    end
  end

  describe "PUT /api/v1/requests/:request_id/offers/:offer_id (AC2)" do
    test "200 on first and second edit; 422 edit_limit_reached on third", %{conn: conn} do
      request = insert_request!()
      jeeber = uuid()

      offer =
        conn
        |> put_req_header("x-user-id", jeeber)
        |> post("/api/v1/requests/#{request.id}/offers", %{
          "fee_cents" => 1_000,
          "eta_minutes" => 10
        })
        |> json_response(201)

      # 1st edit
      first =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", jeeber)
        |> put(
          "/api/v1/requests/#{request.id}/offers/#{offer["id"]}",
          %{"fee_cents" => 1_100}
        )
        |> json_response(200)

      assert first["status"] == "edited"
      assert first["edits_count"] == 1

      # 2nd edit
      second =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", jeeber)
        |> put(
          "/api/v1/requests/#{request.id}/offers/#{offer["id"]}",
          %{"fee_cents" => 1_200}
        )
        |> json_response(200)

      assert second["edits_count"] == 2

      # 3rd edit — must be rejected
      third =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", jeeber)
        |> put(
          "/api/v1/requests/#{request.id}/offers/#{offer["id"]}",
          %{"fee_cents" => 1_300}
        )

      body = json_response(third, 422)
      assert body["error"]["code"] == "edit_limit_reached"
    end

    test "403 when actor is not the offer owner", %{conn: conn} do
      request = insert_request!()
      owner = uuid()
      attacker = uuid()

      offer =
        conn
        |> put_req_header("x-user-id", owner)
        |> post("/api/v1/requests/#{request.id}/offers", %{
          "fee_cents" => 1_000,
          "eta_minutes" => 10
        })
        |> json_response(201)

      resp =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", attacker)
        |> put(
          "/api/v1/requests/#{request.id}/offers/#{offer["id"]}",
          %{"fee_cents" => 1_500}
        )

      assert json_response(resp, 403)["error"]["code"] == "forbidden"
    end
  end

  describe "DELETE /api/v1/requests/:request_id/offers/:offer_id (AC4)" do
    test "200 on successful withdraw", %{conn: conn} do
      request = insert_request!()
      jeeber = uuid()

      offer =
        conn
        |> put_req_header("x-user-id", jeeber)
        |> post("/api/v1/requests/#{request.id}/offers", %{
          "fee_cents" => 1_000,
          "eta_minutes" => 10
        })
        |> json_response(201)

      resp =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", jeeber)
        |> delete("/api/v1/requests/#{request.id}/offers/#{offer["id"]}")
        |> json_response(200)

      assert resp["status"] == "withdrawn"
      refute is_nil(resp["withdrawn_at"])
    end

    test "410 when withdrawing an already-withdrawn offer (AC4)", %{conn: conn} do
      request = insert_request!()
      jeeber = uuid()

      offer =
        conn
        |> put_req_header("x-user-id", jeeber)
        |> post("/api/v1/requests/#{request.id}/offers", %{
          "fee_cents" => 1_000,
          "eta_minutes" => 10
        })
        |> json_response(201)

      _ =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", jeeber)
        |> delete("/api/v1/requests/#{request.id}/offers/#{offer["id"]}")
        |> json_response(200)

      resp =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("x-user-id", jeeber)
        |> delete("/api/v1/requests/#{request.id}/offers/#{offer["id"]}")

      body = json_response(resp, 410)
      assert body["error"]["code"] == "offer_withdrawn"
    end
  end
end
