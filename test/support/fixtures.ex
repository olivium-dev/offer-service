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
    # Accept either the canonical `:actor_id` or the deprecated `:jeeber_id`
    # alias so existing callers keep working; mirror both columns exactly as
    # submit_changeset does.
    actor_id = attrs[:actor_id] || attrs[:jeeber_id] || uuid()

    attrs =
      %{fee_cents: 1_500, eta_minutes: 25, status: "pending", edits_count: 0}
      |> Map.merge(attrs)
      |> Map.merge(%{
        request_id: request.id,
        parent_id: request.id,
        actor_id: actor_id,
        jeeber_id: actor_id
      })

    %Offer{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  @doc "Insert a freshly-submitted offer in the JEB-48 canonical state."
  def insert_submitted_offer!(request, attrs \\ %{}) do
    insert_offer!(request, Map.merge(%{status: "submitted", edits_count: 0}, attrs))
  end
end
