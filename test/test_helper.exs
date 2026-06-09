ExUnit.start()

Mox.defmock(OfferService.Clients.NotificationClientMock,
  for: OfferService.Clients.NotificationClient
)

Ecto.Adapters.SQL.Sandbox.mode(OfferService.Repo, :manual)
