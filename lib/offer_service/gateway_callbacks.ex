defmodule OfferService.GatewayCallbacks do
  @moduledoc """
  Builds durable Gateway callback jobs from committed offer audit events.

  Jobs are inserted through the caller's `Ecto.Multi`, making the business
  mutation, `offer_events` audit row, and Oban job one PostgreSQL transaction.
  HTTP delivery is performed later by `GatewayCallbackWorker`.
  """

  alias Ecto.Multi
  alias OfferService.Auction.OfferEvent
  alias OfferService.Workers.GatewayCallbackWorker

  @default_locale "en"

  @spec enabled?() :: boolean()
  def enabled? do
    config() |> Keyword.get(:enabled, false)
  end

  @doc "Add an Oban insert to `multi` when callbacks are enabled."
  @spec multi_enqueue(Multi.t(), Multi.name(), Multi.name(), (map() -> binary())) :: Multi.t()
  def multi_enqueue(%Multi{} = multi, job_name, event_name, recipient_fun)
      when is_function(recipient_fun, 1) do
    if enabled?() do
      Multi.insert(multi, job_name, fn changes ->
        event = Map.fetch!(changes, event_name)
        recipient_id = recipient_fun.(changes)

        event
        |> job_args(recipient_id)
        |> GatewayCallbackWorker.new(max_attempts: attempts())
      end)
    else
      multi
    end
  end

  @doc "Build the exact `/svc-callbacks/notify` body for one persisted event."
  @spec payload(OfferEvent.t(), binary()) :: map()
  def payload(%OfferEvent{} = event, recipient_id)
      when is_binary(recipient_id) and recipient_id != "" do
    %{
      "notificationType" => notification_type(event.action),
      "recipientUserId" => recipient_id,
      "locale" => locale(),
      "silent" => false,
      "idempotencyKey" => idempotency_key(event.id, recipient_id),
      "data" => %{
        "entityId" => event.offer_id,
        "offerId" => event.offer_id,
        "requestId" => event.request_id,
        "action" => event.action,
        "fromStatus" => event.from_state || "",
        "toStatus" => event.to_state,
        "actorId" => event.actor_id,
        "occurredAt" => DateTime.to_iso8601(event.inserted_at)
      }
    }
  end

  @spec callback_url() :: binary()
  def callback_url do
    cfg = config()
    base_url = Keyword.fetch!(cfg, :base_url)
    path = Keyword.get(cfg, :path, "/svc-callbacks/notify")

    base_url
    |> URI.parse()
    |> Map.put(:path, path)
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: config() |> Keyword.get(:timeout_ms, 5_000)

  @spec request_options() :: keyword()
  def request_options, do: config() |> Keyword.get(:request_options, [])

  defp job_args(event, recipient_id) do
    %{
      "event_id" => event.id,
      "recipient_user_id" => recipient_id,
      "payload" => payload(event, recipient_id)
    }
  end

  defp notification_type("submit"), do: "jeeb.offer_received"
  defp notification_type("accept"), do: "jeeb.offer_accepted"

  defp notification_type(action) when action in ~w(edit withdraw reject expire),
    do: "jeeb.offer_updated"

  defp idempotency_key(event_id, recipient_id),
    do: "offer-event:#{event_id}:recipient:#{recipient_id}"

  defp locale, do: config() |> Keyword.get(:locale, @default_locale)
  defp attempts, do: config() |> Keyword.get(:attempts, 10)
  defp config, do: Application.get_env(:offer_service, :gateway_callbacks, [])
end
