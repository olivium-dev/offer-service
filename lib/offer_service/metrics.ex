defmodule OfferService.Metrics do
  @moduledoc """
  Metrics collection for PromEx polling metrics.
  """

  import Ecto.Query
  require Logger

  alias OfferService.Repo

  @doc """
  Returns the count of active offers (pending or accepted).
  """
  def active_offers_count do
    from(o in "offers",
      where: o.status in ["pending", "accepted"],
      select: count(o.id)
    )
    |> Repo.one()
  rescue
    error ->
      Logger.warning("Failed to fetch active offers count: #{inspect(error)}")
      0
  end
end
