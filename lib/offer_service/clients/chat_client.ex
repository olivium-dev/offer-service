defmodule OfferService.Clients.ChatClient do
  @moduledoc """
  Behaviour for creating a 1:1 chat thread between a Client and a Jeeber for an
  accepted offer. Implementations are swapped via application config so that
  tests can use a Mox-generated mock.
  """

  @type thread_params :: %{
          required(:request_id) => Ecto.UUID.t(),
          required(:offer_id) => Ecto.UUID.t(),
          required(:client_id) => Ecto.UUID.t(),
          required(:jeeber_id) => Ecto.UUID.t()
        }

  @type thread_result :: %{thread_id: String.t()}
  @type error :: {:error, atom() | binary()}

  @callback create_thread(thread_params()) :: {:ok, thread_result()} | error()

  @spec client() :: module()
  def client, do: Application.fetch_env!(:offer_service, :chat_client)

  @spec create_thread(thread_params()) :: {:ok, thread_result()} | error()
  def create_thread(params), do: client().create_thread(params)
end
