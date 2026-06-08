defmodule OfferServiceWeb.RequestControllerTest do
  use OfferServiceWeb.ConnCase, async: false

  import Ecto.Query

  alias OfferService.Auction.Request
  alias OfferService.Repo

  describe "POST /api/v1/requests — request-bridge" do
    test "201 mirrors a gateway-created request", %{conn: conn} do
      id = Ecto.UUID.generate()
      client_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_req_header("x-user-id", client_id)
        |> post("/api/v1/requests", %{"request_id" => id, "client_id" => client_id})

      assert %{
               "id" => ^id,
               "request_id" => ^id,
               "client_id" => ^client_id,
               "status" => "open"
             } = json_response(conn, 201)

      assert %Request{status: "open"} = Repo.get(Request, id)
    end

    test "201 with a NON-UUID opaque client_id (S07 regression — was 500)", %{conn: conn} do
      # The gateway forwards the JWT `sub` (e.g. `s07-sami-client`) as client_id;
      # it is NOT a uuid. Before the uuid->text widening this INSERT raised
      # Postgres 22P02 and the bridge surfaced a 500. It must now 201.
      id = Ecto.UUID.generate()
      opaque_client = "s07-sami-client-9558"

      conn =
        conn
        |> put_req_header("x-user-id", opaque_client)
        |> post("/api/v1/requests", %{"request_id" => id, "client_id" => opaque_client})

      assert %{
               "id" => ^id,
               "client_id" => ^opaque_client,
               "status" => "open"
             } = json_response(conn, 201)

      assert %Request{client_id: ^opaque_client} = Repo.get(Request, id)
    end

    test "200 on idempotent replay with x-idempotency-replay header", %{conn: conn} do
      id = Ecto.UUID.generate()
      client_id = Ecto.UUID.generate()
      body = %{"request_id" => id, "client_id" => client_id}

      conn
      |> put_req_header("x-user-id", client_id)
      |> post("/api/v1/requests", body)
      |> json_response(201)

      replay =
        build_conn()
        |> put_req_header("x-user-id", client_id)
        |> post("/api/v1/requests", body)

      assert %{"id" => ^id, "status" => "open"} = json_response(replay, 200)
      assert ["true"] = Plug.Conn.get_resp_header(replay, "x-idempotency-replay")
      assert Repo.aggregate(from(r in Request, where: r.id == ^id), :count) == 1
    end

    test "401 when x-user-id header is missing", %{conn: conn} do
      conn =
        post(conn, "/api/v1/requests", %{
          "request_id" => Ecto.UUID.generate(),
          "client_id" => Ecto.UUID.generate()
        })

      assert json_response(conn, 401)
    end

    test "400 when request_id is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", Ecto.UUID.generate())
        |> post("/api/v1/requests", %{"client_id" => Ecto.UUID.generate()})

      assert %{"error" => %{"code" => "request_id_required"}} = json_response(conn, 400)
    end

    test "400 when request_id is not a UUID", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", Ecto.UUID.generate())
        |> post("/api/v1/requests", %{"request_id" => "nope", "client_id" => Ecto.UUID.generate()})

      assert %{"error" => %{"code" => "request_id_required"}} = json_response(conn, 400)
    end

    test "422 when client_id is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", Ecto.UUID.generate())
        |> post("/api/v1/requests", %{"request_id" => Ecto.UUID.generate()})

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end
  end
end
