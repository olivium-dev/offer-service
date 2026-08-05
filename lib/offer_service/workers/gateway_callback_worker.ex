defmodule OfferService.Workers.GatewayCallbackWorker do
  @moduledoc """
  Delivers a committed offer lifecycle callback to the Gateway.

  Oban owns retry scheduling and persistence. Gateway failures are returned to
  Oban and never propagate back to the already-committed business operation.
  """

  use Oban.Worker, queue: :notifications

  require Logger

  alias OfferService.GatewayCallbacks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id, "payload" => payload}}) do
    options = [
      url: GatewayCallbacks.callback_url(),
      json: payload,
      receive_timeout: GatewayCallbacks.timeout_ms(),
      retry: false
    ]

    case Req.post(Keyword.merge(options, GatewayCallbacks.request_options())) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("gateway_callback.rejected",
          event_id: event_id,
          status: status,
          body: inspect(body, limit: 500)
        )

        {:error, "gateway callback returned HTTP #{status}"}

      {:error, exception} ->
        Logger.warning("gateway_callback.failed",
          event_id: event_id,
          reason: Exception.message(exception)
        )

        {:error, exception}
    end
  end
end
