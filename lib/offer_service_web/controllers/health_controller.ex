defmodule OfferServiceWeb.HealthController do
  use OfferServiceWeb, :controller

  alias OfferService.Repo

  def live(conn, _), do: json(conn, %{status: "ok"})

  def ready(conn, _) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} ->
        json(conn, %{status: "ready"})

      {:error, _} ->
        conn
        |> put_status(503)
        |> json(%{status: "unready", reason: "db_unreachable"})
    end
  end
end
