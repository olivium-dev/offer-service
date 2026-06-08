defmodule OfferServiceWeb.AcceptByOfferControllerTest do
  @moduledoc """
  HTTP contract for the offer-scoped accept route (S07 / OS-4):
  `POST /api/v1/offers/:offer_id/accept`.

  This is the route the Jeeb gateway forwards `POST /offers/{offer_id}/accept`
  to — it carries no request_id, so offer-service resolves it from the offer and
  authorizes on request-CLIENT ownership (the Client who created the request is
  the only authorized acceptor; a Jeeber -> 403). Mirrors the request-scoped
  controller test conventions (x-user-id auth header, idempotency-key header,
  Mox-stubbed cross-service clients).

  Auth identities use NON-UUID opaque `x-user-id` values (the gateway JWT `sub`,
  e.g. `s07-sami-client-9558`) to exercise the a3 uuid->text column widening.
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

  defp client_id(who), do: "s07-#{who}-client-" <> Integer.to_string(:rand.uniform(9999))
  defp jeeber_id(who), do: "s07-#{who}-jeeber-" <> Integer.to_string(:rand.uniform(9999))

  describe "POST /api/v1/offers/:offer_id/accept" do
    test "200 — the request CLIENT accepts a Jeeber offer and gets the accept envelope",
         %{conn: conn} do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      offer = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "thread-os4"}} end)

      conn =
        conn
        |> put_req_header("x-user-id", client)
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

    test "403 — the offer's OWN Jeeber cannot accept its own bid; the saga never runs",
         %{conn: conn} do
      request = insert_request!(%{client_id: client_id("sami")})
      offer = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      # No ChatClientMock expectation: a 200 would fail verify_on_exit!.
      conn =
        conn
        |> put_req_header("x-user-id", offer.jeeber_id)
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/offers/#{offer.id}/accept")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "403 — a different client (not the request owner) is rejected", %{conn: conn} do
      request = insert_request!(%{client_id: client_id("sami")})
      offer = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      conn =
        conn
        |> put_req_header("x-user-id", client_id("intruder"))
        |> put_req_header("idempotency-key", "idem-" <> Ecto.UUID.generate())
        |> post("/api/v1/offers/#{offer.id}/accept")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "404 — phantom offer id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", client_id("sami"))
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
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      offer = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      conn =
        conn
        |> put_req_header("x-user-id", client)
        |> post("/api/v1/offers/#{offer.id}/accept")

      assert json_response(conn, 400)["error"]["code"] == "idempotency_key_required"
    end
  end
end
