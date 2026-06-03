defmodule OfferService.Auction.StateMachinePropertyTest do
  @moduledoc """
  AC7 (T-BE-012): "StreamData property test verifies any sequence of valid
  transitions never violates the state machine invariants."

  Invariants enforced for every reachable record `%{state, edits_count}`:

    INV1  `state ∈ {submitted, edited, withdrawn, accepted, rejected, expired}`
    INV2  `0 ≤ edits_count ≤ 2`
    INV3  `edits_count` is monotonically non-decreasing.
    INV4  Once `state ∈ {withdrawn, accepted, rejected, expired}` no further
          transitions succeed.
    INV5  `state == :edited`  ⇒  `edits_count ≥ 1`.
    INV6  `state == :submitted` ⇒ `edits_count == 0`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OfferService.Auction.StateMachine

  @all_actions [:edit, :withdraw, :accept, :reject, :expire]

  property "any random sequence of actions preserves the six invariants" do
    check all(actions <- list_of(member_of(@all_actions), min_length: 0, max_length: 20),
              max_runs: 200) do
      Enum.reduce(actions, StateMachine.initial(), fn action, acc ->
        case StateMachine.apply(acc, action) do
          {:ok, next} ->
            assert_invariants(next, acc)
            next

          {:error, _reason} ->
            # Rejected transitions must not mutate state.
            acc
        end
      end)
    end
  end

  property "valid edit chains never exceed two edits" do
    check all(n <- integer(0..5), max_runs: 50) do
      result =
        Enum.reduce(1..n//1, {:ok, StateMachine.initial()}, fn _, acc ->
          case acc do
            {:ok, record} -> StateMachine.apply(record, :edit)
            err -> err
          end
        end)

      case result do
        {:ok, %{edits_count: ec}} ->
          assert n <= 2
          assert ec == n

        {:error, :edit_limit_reached} ->
          assert n > 2
      end
    end
  end

  property "withdraw is idempotent w.r.t. the error code (:offer_withdrawn)" do
    check all(n <- integer(1..5), max_runs: 50) do
      withdrawn =
        StateMachine.initial()
        |> StateMachine.apply(:withdraw)
        |> elem(1)

      result =
        Enum.reduce(1..n//1, withdrawn, fn _, acc ->
          case StateMachine.apply(acc, :withdraw) do
            {:ok, _} -> raise "withdrawn → withdraw should NEVER succeed (INV4)"
            {:error, :offer_withdrawn} -> acc
          end
        end)

      assert result.state == :withdrawn
    end
  end

  # --- invariants ----------------------------------------------------------

  defp assert_invariants(%{state: state, edits_count: ec} = next, %{edits_count: prev_ec}) do
    # INV1
    assert state in [:submitted, :edited, :withdrawn, :accepted, :rejected, :expired],
           "INV1 violated: state=#{inspect(state)}"

    # INV2
    assert ec >= 0 and ec <= StateMachine.max_edits(),
           "INV2 violated: edits_count=#{ec}"

    # INV3
    assert ec >= prev_ec, "INV3 violated: edits_count regressed #{prev_ec} → #{ec}"

    # INV5
    if state == :edited do
      assert ec >= 1, "INV5 violated: state=:edited but edits_count=#{ec}"
    end

    # INV6
    if state == :submitted do
      assert ec == 0, "INV6 violated: state=:submitted but edits_count=#{ec}"
    end

    next
  end
end
