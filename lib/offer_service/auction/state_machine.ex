defmodule OfferService.Auction.StateMachine do
  @moduledoc """
  Pure state machine for the offer auction lifecycle.

  Encodes — and is the single source of truth for — the legal transitions
  required by T-BE-012:

      ┌──────────┐  edit   ┌────────┐  edit (≤2x)
      │ submitted├─────────►│ edited ├──────────┐
      └────┬─────┘          └────┬───┘          │
           │ withdraw            │              │
           ▼                     ▼              │
      ┌──────────┐          ┌──────────┐        │
      │withdrawn │          │withdrawn │◄───────┘
      └──────────┘          └──────────┘

      submitted | edited ──accept──► accepted
                          ──reject──► rejected
                          ──expire──► expired

  Implemented as pure data so that:

    * Both the Ecto-backed flows (`Submit`, `Edit`, `Withdraw`, `Acceptance`)
      and the StreamData property test exercise the *same* code path —
      they cannot drift.
    * Every transition that the database must persist can be derived from
      `apply/2` without an `Ecto.Repo` round-trip first.

  ## States

  `:submitted | :edited | :withdrawn | :accepted | :rejected | :expired`

  The legacy `:pending` value persisted by the JEB-47 acceptance flow is
  treated as an alias of `:submitted` for read-side purposes via
  `normalize_state/1` — the database constraint accepts it, but no new code
  emits it.

  ## Actions

  `:submit | :edit | :withdraw | :accept | :reject | :expire`
  """

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

  @max_edits 2

  @doc "Initial record for a freshly submitted offer."
  @spec initial() :: record()
  def initial, do: %{state: :submitted, edits_count: 0}

  @doc "Maximum number of edits permitted before edit_limit_reached."
  @spec max_edits() :: pos_integer()
  def max_edits, do: @max_edits

  @doc "Treat the legacy `:pending` state as `:submitted`."
  @spec normalize_state(atom() | binary()) :: state() | :unknown
  def normalize_state(state) when is_binary(state), do: normalize_state(String.to_atom(state))
  def normalize_state(:pending), do: :submitted
  def normalize_state(s) when s in [:submitted, :edited, :withdrawn, :accepted, :rejected, :expired], do: s
  def normalize_state(_), do: :unknown

  @doc """
  Apply `action` to `record`, returning the next state or a structured
  error. Pure: never touches the database, never logs, never emits
  telemetry.
  """
  @spec apply(record(), action()) :: {:ok, record()} | {:error, error()}
  def apply(%{state: state} = record, action) do
    do_apply(normalize(record), action) |> annotate(record, action, state)
  end

  # --- transition table ----------------------------------------------------

  defp do_apply(%{state: :submitted, edits_count: 0}, :submit), do: {:error, :already_submitted}

  defp do_apply(%{state: :submitted, edits_count: ec}, :edit) when ec < @max_edits,
    do: {:ok, %{state: :edited, edits_count: ec + 1}}

  defp do_apply(%{state: :edited, edits_count: ec}, :edit) when ec < @max_edits,
    do: {:ok, %{state: :edited, edits_count: ec + 1}}

  defp do_apply(%{state: s, edits_count: ec}, :edit) when s in [:submitted, :edited] and ec >= @max_edits,
    do: {:error, :edit_limit_reached}

  defp do_apply(%{state: s} = r, :withdraw) when s in [:submitted, :edited],
    do: {:ok, %{r | state: :withdrawn}}

  defp do_apply(%{state: s} = r, :accept) when s in [:submitted, :edited],
    do: {:ok, %{r | state: :accepted}}

  defp do_apply(%{state: s} = r, :reject) when s in [:submitted, :edited],
    do: {:ok, %{r | state: :rejected}}

  defp do_apply(%{state: s} = r, :expire) when s in [:submitted, :edited],
    do: {:ok, %{r | state: :expired}}

  defp do_apply(%{state: :withdrawn}, _), do: {:error, :offer_withdrawn}
  defp do_apply(%{state: :accepted}, _), do: {:error, :already_accepted}
  defp do_apply(%{state: :rejected}, _), do: {:error, :already_rejected}
  defp do_apply(%{state: :expired}, _), do: {:error, :offer_expired}

  defp do_apply(_record, _action), do: {:error, :invalid_transition}

  # --- helpers -------------------------------------------------------------

  defp normalize(%{state: state, edits_count: ec}) when is_integer(ec) and ec >= 0 do
    %{state: normalize_state(state), edits_count: ec}
  end

  defp normalize(%{state: state}), do: %{state: normalize_state(state), edits_count: 0}

  defp annotate({:ok, next}, _record, _action, _prev), do: {:ok, next}
  defp annotate({:error, _} = err, _record, _action, _prev), do: err
end
