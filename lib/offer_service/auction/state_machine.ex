defmodule OfferService.Auction.StateMachine do
  @moduledoc """
  Pure state machine for the offer auction lifecycle.

  Encodes — and is the single source of truth for — the legal transitions:

      submitted ──edit──► edited ──edit (≤ max_edits)──► edited
      submitted | edited ──withdraw──► withdrawn
      submitted | edited ──accept──► accepted
      submitted | edited ──reject──► rejected
      submitted | edited ──expire──► expired

  Implemented as pure data so that the Ecto-backed flows and the property test
  exercise the *same* code path and cannot drift.

  ## States

  `:submitted | :edited | :withdrawn | :accepted | :rejected | :expired`

  The legacy `:pending` value is treated as an alias of `:submitted` for
  read-side purposes via `normalize_state/1` — the database constraint accepts
  it, but no new code emits it.

  ## Actions

  `:submit | :edit | :withdraw | :accept | :reject | :expire`

  ## Edit cap (configurable)

  The number of edits permitted before `:edit_limit_reached` is NOT hardcoded.
  It is supplied per call (`apply/3`) or falls back to the configurable
  `:max_edits` application env. When the resolved cap is `nil`, no upper bound
  is enforced — the consuming product owns the policy.
  """

  # This module defines its own `apply/2` and `apply/3` transition entrypoints,
  # which would otherwise clash with the auto-imported `Kernel.apply`.
  import Kernel, except: [apply: 2, apply: 3]

  @type state ::
          :submitted
          | :edited
          | :withdrawn
          | :accepted
          | :rejected
          | :expired

  @type action :: :submit | :edit | :withdraw | :accept | :reject | :expire

  @type record :: %{state: state(), edits_count: non_neg_integer()}

  @type error ::
          :already_submitted
          | :edit_limit_reached
          | :offer_withdrawn
          | :offer_not_pending
          | :already_accepted
          | :already_rejected
          | :offer_expired
          | :invalid_transition

  @doc "Initial record for a freshly submitted offer."
  @spec initial() :: record()
  def initial, do: %{state: :submitted, edits_count: 0}

  @doc """
  Configurable maximum number of edits permitted before `:edit_limit_reached`.

  Resolved from the `:max_edits` application env. Returns `nil` (no
  service-imposed ceiling) when unset — the consumer supplies the policy.
  """
  @spec max_edits() :: pos_integer() | nil
  def max_edits, do: Application.get_env(:offer_service, :max_edits)

  @doc "Treat the legacy `:pending` state as `:submitted`."
  @spec normalize_state(atom() | binary()) :: state() | :unknown
  def normalize_state(state) when is_binary(state), do: normalize_state(String.to_atom(state))
  def normalize_state(:pending), do: :submitted

  def normalize_state(s)
      when s in [:submitted, :edited, :withdrawn, :accepted, :rejected, :expired],
      do: s

  def normalize_state(_), do: :unknown

  @doc """
  Apply `action` to `record` using the configurable default edit cap
  (`max_edits/0`). Pure: never touches the database, never logs, never emits
  telemetry.
  """
  @spec apply(record(), action()) :: {:ok, record()} | {:error, error()}
  def apply(record, action), do: apply(record, action, max_edits())

  @doc """
  Apply `action` to `record` with an explicit `max_edits` ceiling
  (`nil` = no upper bound). This is how the consumer supplies its own edit
  policy without the shared service hardcoding it.
  """
  @spec apply(record(), action(), pos_integer() | nil) :: {:ok, record()} | {:error, error()}
  def apply(%{state: _state} = record, action, max_edits) do
    do_apply(normalize(record), action, max_edits)
  end

  # --- transition table ----------------------------------------------------

  defp do_apply(%{state: :submitted, edits_count: 0}, :submit, _max),
    do: {:error, :already_submitted}

  defp do_apply(%{state: s, edits_count: ec}, :edit, max) when s in [:submitted, :edited] do
    if is_nil(max) or ec < max do
      {:ok, %{state: :edited, edits_count: ec + 1}}
    else
      {:error, :edit_limit_reached}
    end
  end

  defp do_apply(%{state: s} = r, :withdraw, _max) when s in [:submitted, :edited],
    do: {:ok, %{r | state: :withdrawn}}

  defp do_apply(%{state: s} = r, :accept, _max) when s in [:submitted, :edited],
    do: {:ok, %{r | state: :accepted}}

  defp do_apply(%{state: s} = r, :reject, _max) when s in [:submitted, :edited],
    do: {:ok, %{r | state: :rejected}}

  defp do_apply(%{state: s} = r, :expire, _max) when s in [:submitted, :edited],
    do: {:ok, %{r | state: :expired}}

  defp do_apply(%{state: :withdrawn}, _, _max), do: {:error, :offer_withdrawn}
  defp do_apply(%{state: :accepted}, _, _max), do: {:error, :already_accepted}
  defp do_apply(%{state: :rejected}, _, _max), do: {:error, :already_rejected}
  defp do_apply(%{state: :expired}, _, _max), do: {:error, :offer_expired}

  defp do_apply(_record, _action, _max), do: {:error, :invalid_transition}

  # --- helpers -------------------------------------------------------------

  defp normalize(%{state: state, edits_count: ec}) when is_integer(ec) and ec >= 0 do
    %{state: normalize_state(state), edits_count: ec}
  end

  defp normalize(%{state: state}), do: %{state: normalize_state(state), edits_count: 0}
end
