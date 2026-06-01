defmodule OfferServiceWeb.HealthControllerTest do
  use OfferServiceWeb.ConnCase
  alias OfferService.Repo

  describe "GET /health" do
    test "returns ok", %{conn: conn} do
      conn = get(conn, "/health")
      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end

  describe "GET /health/ready" do
    test "returns ready when database is available", %{conn: conn} do
      conn = get(conn, "/health/ready")
      assert json_response(conn, 200) == %{"status" => "ready"}
    end
  end
end
