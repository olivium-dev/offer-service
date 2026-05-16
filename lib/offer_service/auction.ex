defmodule OfferService.Auction do
  @moduledoc """
  Public API for the offer auction domain.

  Only this module should be called from the web layer; everything below is
  considered internal to the bounded context.
  """

  alias OfferService.Auction.Acceptance

  defdelegate accept_offer(actor_id, request_id, offer_id, opts \\ []), to: Acceptance, as: :run
end
