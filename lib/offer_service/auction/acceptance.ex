defmodule OfferService.Auction.Acceptance do
  @moduledoc """
  Implements the generic auction-close transition for
  `POST /requests/:id/offers/:id/accept`.

  The flow runs in a single Postgres transaction so that the state changes
  — accept-target / reject-siblings / transition-parent — either all commit or
  all roll back. Concurrent acceptance attempts are blocked at two levels:

    1. The parent row is locked with `SELECT ... FOR UPDATE`.
    2. The `Request` row carries a `lock_version` integer; the changeset uses
       `Ecto.Changeset.optimistic_lock/2`, so a stale read raises
       `Ecto.StaleEntryError` and the whole transaction is rolled back.

  ## Boundary (JEB-1474)

  This shared service owns ONLY the generic single-winner transition. It returns
  the accepted offer id and the rejected sibling ids — nothing product-specific.
  Product-domain side effects that used to run here — OTP-on-accept,
  conversation/chat-thread creation, the parent's chat-thread linkage, and push
  notification fan-out — have been moved OUT of this service and INTO the
  consuming gateway, which orchestrates them via its typed clients after a
  successful accept. Services never call each other; all cross-service
  composition lives in the gateway.

  Returned value on success:
  `{:ok, %{request: ..., accepted_offer: ..., rejected_offer_ids: [...]}}`.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias OfferService.Auction.{AuditLog, Offer, OfferEvent, Request}
  alias OfferService.Repo

  # Opaque external identity (gateway JWT `sub`), not necessarily a uuid.
  @type acceptor_id :: binary()
  @type request_id :: Ecto.UUID.t()
  @type offer_id :: Ecto.UUID.t()
  @type opts :: [confirm_high_fee: boolean(), authorize: boolean()]

  @type success :: %{
          request: Request.t(),
          accepted_offer: Offer.t(),
          rejected_offer_ids: [Ecto.UUID.t()]
        }

  @type error_reason ::
          :not_found
          | :forbidden
          | :request_not_open
          | :request_expired
          | :request_cancelled
          | :offer_not_pending
          | :offer_withdrawn
          | :offer_expired
          | {:already_accepted, Ecto.UUID.t() | nil}
          | :already_accepted
          | :concurrent_modification
          | :high_fee_confirmation_required

  @spec run(acceptor_id(), request_id(), offer_id(), opts()) ::
          {:ok, success()} | {:error, error_reason()}
  def run(actor_id, request_id, offer_id, opts \\ []) do
    confirm_high_fee? = Keyword.get(opts, :confirm_high_fee, false)
    # `authorize: false` bypasses the request-owner guard below. It is reserved
    # for internal/trusted callers that have ALREADY authorized the actor
    # out-of-band; no HTTP route currently sets it. Both public accept routes
    # keep the default `true`, so the owner guard (`request.client_id ==
    # actor_id` => 403) is the single source of truth.
    authorize? = Keyword.get(opts, :authorize, true)
    threshold = Application.get_env(:offer_service, :high_fee_threshold_cents, 5_000)
    started_at = System.monotonic_time()

    result =
      Multi.new()
      |> Multi.run(:request, fn repo, _ ->
        lock_request(repo, request_id, actor_id, authorize?)
      end)
      |> Multi.run(:offer, fn repo, %{request: r} -> load_target_offer(repo, r.id, offer_id) end)
      |> Multi.run(:high_fee_guard, fn _repo, %{offer: o} ->
        check_high_fee(o, confirm_high_fee?, threshold)
      end)
      |> Multi.update(:accepted_offer, fn %{offer: o} -> Offer.accept_changeset(o, now()) end)
      |> Multi.run(:rejected_offer_ids, fn repo, %{request: r, offer: o} ->
        reject_siblings(repo, r.id, o.id)
      end)
      # The parent's chat-thread linkage is owned by the gateway BFF (JEB-1474):
      # this service transitions the parent to `accepted` with the winning offer
      # id only and never writes a conversation/chat linkage.
      |> Multi.update(:final_request, fn %{request: r, accepted_offer: o} ->
        Request.accept_changeset(r, %{accepted_offer_id: o.id})
      end)
      |> Multi.insert(:audit_accept, fn %{offer: prev, accepted_offer: next} ->
        OfferEvent.new_changeset(%{
          offer_id: next.id,
          request_id: next.request_id,
          actor_id: actor_id,
          action: "accept",
          from_state: prev.status,
          to_state: next.status,
          payload: %{"fee_cents" => next.fee_cents},
          inserted_at: DateTime.utc_now()
        })
      end)
      |> Repo.transaction()
      |> handle_result(actor_id)

    emit_accept_outcome(result, request_id, started_at)
    result
  rescue
    Ecto.StaleEntryError ->
      :telemetry.execute(
        [:offer, :accept, :outcome],
        %{count: 1, duration: 0},
        %{outcome: :concurrent_modification}
      )

      {:error, :concurrent_modification}
  end

  # Emit the product-agnostic `offer_accept_total{outcome}` counter and a
  # structured log. No product-taxonomy naming.
  defp emit_accept_outcome(result, request_id, started_at) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    {outcome, extra} =
      case result do
        {:ok, %{accepted_offer: accepted}} ->
          {:ok, %{winner_user_id: accepted.actor_id}}

        {:error, {:already_accepted, winner}} ->
          {:already_accepted, %{winner_user_id: winner}}

        {:error, reason} when is_atom(reason) ->
          {reason, %{}}

        _ ->
          {:error, %{}}
      end

    :telemetry.execute(
      [:offer, :accept, :outcome],
      %{count: 1, duration: duration_ms},
      Map.merge(%{outcome: outcome, request_id: request_id}, extra)
    )

    Logger.info("offer.accepted",
      request_id: request_id,
      outcome: outcome,
      latency_ms: duration_ms,
      winner_user_id: extra[:winner_user_id]
    )
  end

  # --- Multi steps ---------------------------------------------------------

  defp lock_request(repo, request_id, actor_id, authorize?) do
    query =
      from r in Request,
        where: r.id == ^request_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil ->
        {:error, :not_found}

      # Owner guard — the authorized acceptor is the client who owns the parent
      # request (`request.client_id == actor_id`). Any other actor is rejected
      # with 403. Only trusted internal callers opt out via `authorize: false`.
      %Request{client_id: client_id} when authorize? and client_id != actor_id ->
        {:error, :forbidden}

      %Request{status: "open"} = request ->
        {:ok, request}

      # Race-loss path. The second of two simultaneous `Accept` calls blocks on
      # the row-lock above; once the first commits, this transaction sees the
      # request already accepted and returns the winner's actor id so the API
      # caller can render `{ error: "already_accepted", winner_user_id }`.
      %Request{status: "accepted"} = request ->
        {:error, {:already_accepted, winner_user_id(repo, request)}}

      # Terminal lifecycle states map to HTTP 410.
      %Request{status: "expired"} ->
        {:error, :request_expired}

      %Request{status: "cancelled"} ->
        {:error, :request_cancelled}

      %Request{} ->
        {:error, :request_not_open}
    end
  end

  defp winner_user_id(_repo, %Request{accepted_offer_id: nil}), do: nil

  defp winner_user_id(repo, %Request{accepted_offer_id: accepted_offer_id}) do
    case repo.get(Offer, accepted_offer_id) do
      %Offer{actor_id: aid} -> aid
      _ -> nil
    end
  end

  defp load_target_offer(repo, request_id, offer_id) do
    case repo.get_by(Offer, id: offer_id, request_id: request_id) do
      nil ->
        {:error, :not_found}

      %Offer{status: s} = offer when s in ["pending", "submitted", "edited"] ->
        {:ok, offer}

      %Offer{status: "withdrawn"} ->
        {:error, :offer_withdrawn}

      # Terminal lifecycle state — accepting an expired offer maps to HTTP 410
      # (BR-OFR-8), distinct from the 409 catch-all below. The `:offer_expired`
      # tag is already mapped to 410 in `OfferServiceWeb.FallbackController`.
      %Offer{status: "expired"} ->
        {:error, :offer_expired}

      %Offer{status: "accepted"} ->
        {:error, :already_accepted}

      _ ->
        {:error, :offer_not_pending}
    end
  end

  defp check_high_fee(%Offer{fee_cents: fee}, _confirmed?, threshold) when fee <= threshold,
    do: {:ok, :under_threshold}

  defp check_high_fee(%Offer{}, true, _threshold), do: {:ok, :confirmed}

  defp check_high_fee(%Offer{}, _confirmed?, _threshold),
    do: {:error, :high_fee_confirmation_required}

  defp reject_siblings(repo, request_id, accepted_offer_id) do
    now = now()

    {count, rejected} =
      repo.update_all(
        from(o in Offer,
          where:
            o.request_id == ^request_id and
              o.id != ^accepted_offer_id and
              o.status in ["pending", "submitted", "edited"],
          select: %{id: o.id, actor_id: o.actor_id, status: o.status}
        ),
        set: [status: "rejected", rejected_at: now, updated_at: now],
        inc: [lock_version: 1]
      )

    Logger.info("offer_acceptance.rejected_siblings",
      request_id: request_id,
      accepted_offer_id: accepted_offer_id,
      rejected_count: count
    )

    {:ok, rejected}
  end

  # --- Post-commit ---------------------------------------------------------

  defp handle_result({:ok, ctx}, actor_id) do
    %{
      offer: prev,
      accepted_offer: accepted,
      rejected_offer_ids: rejected,
      final_request: final_request
    } = ctx

    rejected_ids = Enum.map(rejected, & &1.id)

    AuditLog.emit_telemetry(%{
      offer_id: accepted.id,
      request_id: final_request.id,
      actor_id: actor_id,
      action: :accept,
      from_state: prev.status,
      to_state: "accepted"
    })

    Enum.each(rejected, fn %{id: id, actor_id: rejected_actor_id, status: from} ->
      AuditLog.log!(%{
        offer_id: id,
        request_id: final_request.id,
        actor_id: actor_id,
        action: :reject,
        from_state: from,
        to_state: "rejected",
        payload: %{"sibling_of" => accepted.id}
      })

      AuditLog.emit_telemetry(%{
        offer_id: id,
        request_id: final_request.id,
        actor_id: rejected_actor_id,
        action: :reject,
        from_state: from,
        to_state: "rejected"
      })
    end)

    {:ok,
     %{
       request: final_request,
       accepted_offer: %{accepted | status: "accepted"},
       rejected_offer_ids: rejected_ids
     }}
  end

  defp handle_result({:error, _step, reason, _changes}, _actor_id) when is_atom(reason),
    do: {:error, reason}

  defp handle_result({:error, _step, {:already_accepted, winner}, _changes}, _actor_id),
    do: {:error, {:already_accepted, winner}}

  defp handle_result({:error, _step, %Ecto.Changeset{}, _changes}, _actor_id),
    do: {:error, :concurrent_modification}

  defp handle_result({:error, _step, _other, _changes}, _actor_id),
    do: {:error, :concurrent_modification}

  defp now, do: DateTime.utc_now()
end
