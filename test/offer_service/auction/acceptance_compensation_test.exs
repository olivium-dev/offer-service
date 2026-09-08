defmodule OfferService.Auction.AcceptanceCompensationTest do
  use OfferService.DataCase, async: false

  alias OfferService.Auction
  alias OfferService.Auction.{AcceptanceIdempotencyKey, Offer, OfferEvent, Request}
  alias OfferService.Repo

  defp key, do: "accept-compensation-" <> Ecto.UUID.generate()

  defp accept!(request, target, accept_key) do
    assert {:ok, :fresh, _} =
             Auction.accept_offer_idempotent(
               accept_key,
               request.client_id,
               request.id,
               target.id,
               confirm_high_fee: true
             )

    assert {:ok, token} =
             Auction.acceptance_compensation_token(
               request.client_id,
               request.id,
               target.id,
               accept_key
             )

    token
  end

  test "restores the exact accepted auction, removes its idempotency generation, and is replay-safe" do
    request = insert_request!()
    target = insert_submitted_offer!(request)
    sibling = insert_offer!(request, %{status: "pending"})
    accept_key = key()
    token = accept!(request, target, accept_key)

    assert {:ok, :compensated} =
             Auction.compensate_accepted_offer(
               request.client_id,
               request.id,
               target.id,
               accept_key,
               token
             )

    restored_request = Repo.get!(Request, request.id)
    restored_target = Repo.get!(Offer, target.id)
    restored_sibling = Repo.get!(Offer, sibling.id)

    assert restored_request.status == "open"
    assert is_nil(restored_request.accepted_offer_id)
    assert restored_target.status == "submitted"
    assert is_nil(restored_target.accepted_at)
    assert restored_sibling.status == "pending"
    assert is_nil(restored_sibling.rejected_at)

    refute Repo.exists?(from k in AcceptanceIdempotencyKey, where: k.compensation_token == ^token)

    audit =
      Repo.one!(
        from e in OfferEvent,
          where:
            e.request_id == ^request.id and e.offer_id == ^target.id and
              e.action == "accept_compensated"
      )

    assert audit.payload["acceptance_token"] == token
    assert audit.payload["restored_sibling_offer_ids"] == [sibling.id]

    assert {:ok, :replay} =
             Auction.compensate_accepted_offer(
               request.client_id,
               request.id,
               target.id,
               accept_key,
               token
             )

    # The stable gateway key is usable again after a confirmed compensation.
    # This creates a NEW generation token, and an old delayed compensation is
    # a harmless replay rather than an undo of the newer acceptance.
    assert {:ok, :fresh, _} =
             Auction.accept_offer_idempotent(
               accept_key,
               request.client_id,
               request.id,
               target.id,
               confirm_high_fee: true
             )

    assert {:ok, newer_token} =
             Auction.acceptance_compensation_token(
               request.client_id,
               request.id,
               target.id,
               accept_key
             )

    refute newer_token == token

    assert {:ok, :replay} =
             Auction.compensate_accepted_offer(
               request.client_id,
               request.id,
               target.id,
               accept_key,
               token
             )

    assert Repo.get!(Request, request.id).status == "accepted"
    assert Repo.get!(Offer, target.id).status == "accepted"
  end

  test "never partially restores when a sibling is no longer in the accepted saga's rejected state" do
    request = insert_request!()
    target = insert_submitted_offer!(request)
    sibling = insert_submitted_offer!(request)
    accept_key = key()
    token = accept!(request, target, accept_key)

    # Simulates external data corruption or a conflicting late mutation. The
    # compensation must reject rather than restoring the winner and leaving the
    # request/sibling in a mixed lifecycle.
    Repo.update!(Ecto.Changeset.change(Repo.get!(Offer, sibling.id), status: "withdrawn"))

    assert {:error, :accept_not_current} =
             Auction.compensate_accepted_offer(
               request.client_id,
               request.id,
               target.id,
               accept_key,
               token
             )

    assert Repo.get!(Request, request.id).status == "accepted"
    assert Repo.get!(Request, request.id).accepted_offer_id == target.id
    assert Repo.get!(Offer, target.id).status == "accepted"
    assert Repo.get!(Offer, sibling.id).status == "withdrawn"
    assert Repo.exists?(from k in AcceptanceIdempotencyKey, where: k.compensation_token == ^token)
  end
end
