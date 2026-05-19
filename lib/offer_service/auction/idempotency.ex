defmodule OfferService.Auction.Idempotency do
  @moduledoc """
  Idempotency layer for the offer-accept endpoint (JEB-49 / AC2).

  Contract:

    * `Idempotency-Key` is **mandatory** on `POST /…/accept`.
    * The same key replayed by the same `client_id` on the same
      `request_id` returns the cached response verbatim — no second
      OTP, no second chat thread, no duplicate push notifications.
    * The same key replayed with a divergent payload fingerprint
      (i.e. a different `offer_id` or opts) returns
      `{:error, :idempotency_mismatch}` — RFC 8943-style rejection.

  This module owns the **persist-or-replay** decision and delegates
  the actual accept work to `OfferService.Auction.Acceptance`, keeping
  the saga free of caching concerns.
  """

  import Ecto.Query

  require Logger

  alias OfferService.Auction.{Acceptance, AcceptanceIdempotencyKey}
  alias OfferService.Repo

  @type actor_id :: Ecto.UUID.t()
  @type request_id :: Ecto.UUID.t()
  @type offer_id :: Ecto.UUID.t()
  @type idem_key :: binary()

  @type result ::
          {:ok, :fresh, map()}
          | {:ok, :replay, map()}
          | {:error, Acceptance.error_reason() | :idempotency_mismatch}

  @typedoc """
  A function the caller (typically the controller) provides to convert
  the raw saga response into the wire-shaped map that should be cached
  and returned to the client.

  Defaults to identity so callers that don't care about wire shape
  (unit tests, internal callers) still get a meaningful response.
  """
  @type serializer :: (Acceptance.success() -> map())

  @doc """
  Run the accept flow with idempotency.

  Returns:

    * `{:ok, :fresh, wire_response}` — first time the key was seen;
      the saga ran, `serializer` was applied, and the wire-shaped
      response was persisted in `acceptance_idempotency_keys`.
    * `{:ok, :replay, wire_response}` — the key matched a stored entry
      for the same `(client_id, request_id)` with the same
      fingerprint; the saga was **not** re-executed.
    * `{:error, :idempotency_mismatch}` — same key, different
      payload — rejected.
    * any other `{:error, reason}` propagated from `Acceptance.run/4`.
  """
  @spec run(
          idem_key(),
          actor_id(),
          request_id(),
          offer_id(),
          Acceptance.opts(),
          serializer()
        ) :: result()
  def run(idempotency_key, actor_id, request_id, offer_id, opts \\ [], serializer \\ &(&1))
      when is_binary(idempotency_key) do
    fingerprint = fingerprint(actor_id, request_id, offer_id, opts)

    case load(actor_id, request_id, idempotency_key) do
      nil ->
        fresh_run(
          idempotency_key,
          actor_id,
          request_id,
          offer_id,
          opts,
          fingerprint,
          serializer
        )

      %AcceptanceIdempotencyKey{request_fingerprint: ^fingerprint, response: response} ->
        Logger.info("offer_acceptance.idempotency.replay",
          request_id: request_id,
          idempotency_key: idempotency_key
        )

        emit_outcome(:replay)
        {:ok, :replay, response}

      %AcceptanceIdempotencyKey{} ->
        Logger.warning("offer_acceptance.idempotency.mismatch",
          request_id: request_id,
          idempotency_key: idempotency_key
        )

        emit_outcome(:idempotency_mismatch)
        {:error, :idempotency_mismatch}
    end
  end

  # --- internal ------------------------------------------------------------

  defp fresh_run(
         idempotency_key,
         actor_id,
         request_id,
         offer_id,
         opts,
         fingerprint,
         serializer
       ) do
    case Acceptance.run(actor_id, request_id, offer_id, opts) do
      {:ok, response} ->
        wire = response |> serializer.() |> serialise()

        case persist(idempotency_key, actor_id, request_id, offer_id, fingerprint, wire) do
          {:ok, _row} ->
            {:ok, :fresh, wire}

          {:error, %Ecto.Changeset{} = cs} ->
            handle_persist_conflict(cs, actor_id, request_id, idempotency_key, fingerprint)
        end

      {:error, _reason} = err ->
        err
    end
  end

  defp handle_persist_conflict(cs, actor_id, request_id, idempotency_key, fingerprint) do
    if has_unique_violation?(cs.errors) do
      case load(actor_id, request_id, idempotency_key) do
        %AcceptanceIdempotencyKey{request_fingerprint: ^fingerprint, response: cached} ->
          {:ok, :replay, cached}

        %AcceptanceIdempotencyKey{} ->
          {:error, :idempotency_mismatch}

        nil ->
          {:error, :concurrent_modification}
      end
    else
      {:error, :concurrent_modification}
    end
  end

  defp persist(idempotency_key, actor_id, request_id, offer_id, fingerprint, response) do
    %{
      idempotency_key: idempotency_key,
      client_id: actor_id,
      request_id: request_id,
      offer_id: offer_id,
      request_fingerprint: fingerprint,
      response: response,
      status: "succeeded"
    }
    |> AcceptanceIdempotencyKey.new_changeset()
    |> Repo.insert()
  end

  defp load(actor_id, request_id, idempotency_key) do
    Repo.one(
      from k in AcceptanceIdempotencyKey,
        where:
          k.client_id == ^actor_id and
            k.request_id == ^request_id and
            k.idempotency_key == ^idempotency_key
    )
  end

  defp fingerprint(actor_id, request_id, offer_id, opts) do
    payload = %{
      actor_id: to_string(actor_id),
      request_id: to_string(request_id),
      offer_id: to_string(offer_id),
      opts: Enum.sort(opts)
    }

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp has_unique_violation?(errors) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp emit_outcome(outcome) do
    :telemetry.execute(
      [:offer, :accept, :outcome],
      %{count: 1, duration: 0},
      %{outcome: outcome}
    )

    :ok
  end

  # The on-the-wire response carries Ecto schema structs and DateTimes.
  # We coerce the value tree into plain maps + ISO-8601 strings so the
  # JSONB column round-trips losslessly across the encode/decode cycle.
  defp serialise(response) when is_map(response) do
    response
    |> drop_struct()
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), serialise_value(v)} end)
  end

  defp serialise_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialise_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp serialise_value(%_{} = struct) do
    struct
    |> drop_struct()
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), serialise_value(v)} end)
  end

  defp serialise_value(list) when is_list(list), do: Enum.map(list, &serialise_value/1)

  defp serialise_value(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {to_string(k), serialise_value(v)} end)
  end

  defp serialise_value(other), do: other

  defp drop_struct(%_{} = s) do
    s |> Map.from_struct() |> Map.drop([:__meta__])
  end

  defp drop_struct(m) when is_map(m), do: m
end
