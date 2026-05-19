defmodule OfferService.Auction.StateMachineTest do
  use ExUnit.Case, async: true

  alias OfferService.Auction.StateMachine

  describe "initial/0" do
    test "returns submitted with edits_count=0" do
      assert %{state: :submitted, edits_count: 0} = StateMachine.initial()
    end
  end

  describe "normalize_state/1" do
    test "treats :pending as :submitted (JEB-47 legacy alias)" do
      assert StateMachine.normalize_state(:pending) == :submitted
      assert StateMachine.normalize_state("pending") == :submitted
    end

    test "passes the six canonical states through unchanged" do
      for s <- [:submitted, :edited, :withdrawn, :accepted, :rejected, :expired] do
        assert StateMachine.normalize_state(s) == s
        assert StateMachine.normalize_state(Atom.to_string(s)) == s
      end
    end

    test "returns :unknown for garbage" do
      assert StateMachine.normalize_state("garbage") == :unknown
    end
  end

  describe "apply/2 — edit transitions (AC2)" do
    test "first edit: submitted → edited, edits_count 0 → 1" do
      assert {:ok, %{state: :edited, edits_count: 1}} =
               StateMachine.apply(StateMachine.initial(), :edit)
    end

    test "second edit: edited(1) → edited(2)" do
      assert {:ok, %{state: :edited, edits_count: 2}} =
               StateMachine.apply(%{state: :edited, edits_count: 1}, :edit)
    end

    test "third edit returns :edit_limit_reached" do
      assert {:error, :edit_limit_reached} =
               StateMachine.apply(%{state: :edited, edits_count: 2}, :edit)
    end

    test "edit on submitted with edits_count already at max returns :edit_limit_reached" do
      assert {:error, :edit_limit_reached} =
               StateMachine.apply(%{state: :submitted, edits_count: 2}, :edit)
    end
  end

  describe "apply/2 — withdraw transitions" do
    test "submitted → withdrawn" do
      assert {:ok, %{state: :withdrawn}} = StateMachine.apply(StateMachine.initial(), :withdraw)
    end

    test "edited → withdrawn" do
      assert {:ok, %{state: :withdrawn}} =
               StateMachine.apply(%{state: :edited, edits_count: 1}, :withdraw)
    end

    test "withdrawn → withdraw returns :offer_withdrawn (AC4)" do
      assert {:error, :offer_withdrawn} =
               StateMachine.apply(%{state: :withdrawn, edits_count: 0}, :withdraw)
    end
  end

  describe "apply/2 — accept transitions" do
    test "submitted → accepted" do
      assert {:ok, %{state: :accepted}} = StateMachine.apply(StateMachine.initial(), :accept)
    end

    test "edited → accepted" do
      assert {:ok, %{state: :accepted}} =
               StateMachine.apply(%{state: :edited, edits_count: 2}, :accept)
    end

    test "withdrawn → accept returns :offer_withdrawn (AC4)" do
      assert {:error, :offer_withdrawn} =
               StateMachine.apply(%{state: :withdrawn, edits_count: 0}, :accept)
    end

    test "accepted → accept returns :already_accepted" do
      assert {:error, :already_accepted} =
               StateMachine.apply(%{state: :accepted, edits_count: 0}, :accept)
    end

    test "rejected → accept returns :already_rejected" do
      assert {:error, :already_rejected} =
               StateMachine.apply(%{state: :rejected, edits_count: 0}, :accept)
    end
  end

  describe "apply/2 — terminal exits" do
    test "all terminal states reject further actions" do
      for s <- [:withdrawn, :accepted, :rejected, :expired],
          a <- [:edit, :withdraw, :accept, :reject, :expire] do
        assert {:error, _} = StateMachine.apply(%{state: s, edits_count: 0}, a)
      end
    end
  end
end
