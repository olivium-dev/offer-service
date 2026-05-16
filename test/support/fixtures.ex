defmodule OfferService.Fixtures do
  @moduledoc "Inline factories for tests — kept tiny on purpose."

  alias OfferService.Auction.{Offer, Request}
  alias OfferService.Repo

  def uuid, do: Ecto.UUID.generate()

  def insert_request!(attrs \\ %{}) do
    attrs = Map.merge(%{client_id: uuid(), status: "open"}, attrs)

    %Request{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  def insert_offer!(request, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          jeeber_id: uuid(),
          fee_cents: 1_500,
          eta_minutes: 25,
          status: "pending"
        },
        attrs
      )
      |> Map.put(:request_id, request.id)

    %Offer{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end
end
