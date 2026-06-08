defmodule OfferService.Clients.NotificationClient do
  @moduledoc """
  Behaviour for fan-out push notifications to all parties of an auction close.
  """

  @type event :: :offer_accepted | :offer_rejected | :auction_closed

  @type notify_params :: %{
          # Opaque external identity (gateway JWT `sub`), not necessarily a uuid.
          required(:user_id) => binary(),
          required(:event) => event(),
          required(:payload) => map()
        }

  @callback notify(notify_params()) :: :ok | {:error, term()}

  @spec client() :: module()
  def client, do: Application.fetch_env!(:offer_service, :notification_client)

  @spec notify(notify_params()) :: :ok | {:error, term()}
  def notify(params), do: client().notify(params)
end
